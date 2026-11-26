"""Côté Python de Gib Vid : extraction + téléchargement via yt-dlp.

Swift appelle les fonctions publiques (`configure`, `update`, `download`) avec
un argument JSON et reçoit du JSON en retour. `_gibvid` est un module C
embarqué dans l'app (voir GibBridge.c) qui renvoie vers Swift.
"""
import hashlib
import json
import os
import re
import shutil
import ssl
import sys
import time
import traceback
import urllib.request
import zipfile

import _gibvid
import gibvid_mp4

_paths = {}

# Photos n'accepte que H.264/HEVC + AAC. Sans ffmpeg, on télécharge la vidéo
# et l'audio séparément puis Swift les assemble avec AVFoundation.
_FORMAT = '/'.join([
    'bv*[vcodec~="^(avc|h264)"]+ba[acodec~="^(mp4a|aac)"]',
    'b[vcodec~="^(avc|h264)"]',
    'bv*[vcodec~="^(hvc|hev|h265)"]+ba[acodec~="^(mp4a|aac)"]',
    'b[vcodec~="^(hvc|hev|h265)"]',
    'b[ext=mp4]',
    'bv*+ba',
    'b',
])
_MAX_ITEMS = 10
_KNOWN_EXTS = {'mp4', 'm4a', 'm4v', 'mov', 'webm', '3gp', 'aac', 'mp3'}


# region: configuration et mises à jour de yt-dlp

def configure(payload):
    _paths.update(json.loads(payload))
    _activate_packages()
    return json.dumps({'version': _active_version()})


def _updates_dir():
    return os.path.join(_paths['support'], 'packages')


def _read_version(package_root):
    try:
        with open(os.path.join(package_root, 'yt_dlp', 'version.py'), encoding='utf-8') as f:
            return re.search(r"__version__\s*=\s*'([^']+)'", f.read()).group(1)
    except (OSError, AttributeError):
        return None


def _version_key(version):
    return tuple(int(part) for part in re.findall(r'\d+', version or '0'))


def _installed_update():
    try:
        with open(os.path.join(_updates_dir(), 'current.txt'), encoding='utf-8') as f:
            root = os.path.join(_updates_dir(), f.read().strip())
    except OSError:
        return None
    return root if _read_version(root) else None


def _activate_packages():
    """Place la version la plus récente de yt-dlp (embarquée ou mise à jour) en tête de sys.path."""
    bundled = _paths['bundle_packages']
    candidates = [bundled]
    if update := _installed_update():
        candidates.append(update)
    best = max(candidates, key=lambda root: _version_key(_read_version(root)))
    for root in candidates:
        while root in sys.path:
            sys.path.remove(root)
    # Le dossier embarqué reste dans le chemin pour certifi.
    sys.path[:0] = [best] if best == bundled else [best, bundled]
    _paths['active'] = best


def _active_version():
    return _read_version(_paths['active'])


def _ssl_context():
    import certifi
    return ssl.create_default_context(cafile=certifi.where())


def _fetch(url, timeout=20):
    with urllib.request.urlopen(url, timeout=timeout, context=_ssl_context()) as response:
        return response.read()


def _pypi_wheel(project, version=None):
    path = f'{project}/{version}/json' if version else f'{project}/json'
    meta = json.loads(_fetch(f'https://pypi.org/pypi/{path}'))
    wheel = next(u for u in meta['urls'] if u['packagetype'] == 'bdist_wheel' and u['filename'].endswith('-py3-none-any.whl'))
    return meta['info'], wheel


def _install_wheel(wheel, target):
    data = _fetch(wheel['url'], timeout=60)
    if hashlib.sha256(data).hexdigest() != wheel['digests']['sha256']:
        raise ValueError(f'Empreinte invalide pour {wheel["filename"]}')
    archive = os.path.join(target, wheel['filename'])
    with open(archive, 'wb') as f:
        f.write(data)
    with zipfile.ZipFile(archive) as z:
        z.extractall(target, [name for name in z.namelist() if '.data/' not in name])
    os.remove(archive)


def update(payload):
    """Installe la dernière version de yt-dlp depuis PyPI (vérifiée par SHA-256)."""
    try:
        info, wheel = _pypi_wheel('yt-dlp')
        latest = info['version']
        if _version_key(latest) <= _version_key(_active_version()):
            return json.dumps({'updated': False, 'version': _active_version()})

        ejs_pin = next(
            (m.group(1) for req in info.get('requires_dist') or []
             if (m := re.match(r'yt-dlp-ejs==([^;\s]+)', req))), None)

        root = _updates_dir()
        target = os.path.join(root, latest)
        staging = target + '.tmp'
        shutil.rmtree(staging, ignore_errors=True)
        os.makedirs(staging)
        _install_wheel(wheel, staging)
        if ejs_pin:
            _install_wheel(_pypi_wheel('yt-dlp-ejs', ejs_pin)[1], staging)
        shutil.rmtree(target, ignore_errors=True)
        os.rename(staging, target)
        with open(os.path.join(root, 'current.txt'), 'w', encoding='utf-8') as f:
            f.write(latest)
        for name in os.listdir(root):
            if name not in (latest, 'current.txt'):
                shutil.rmtree(os.path.join(root, name), ignore_errors=True)

        _unload_ytdlp()
        _activate_packages()
        return json.dumps({'updated': True, 'version': _active_version()})
    except Exception as e:
        traceback.print_exc()
        return json.dumps({'updated': False, 'version': _active_version(), 'error': str(e)})


def _unload_ytdlp():
    for name in list(sys.modules):
        if name.split('.')[0] in ('yt_dlp', 'yt_dlp_ejs', 'gibvid_jsc'):
            del sys.modules[name]

# endregion


# region: téléchargement

def warmup(payload):
    """Importe yt-dlp à l'avance pour que le premier téléchargement soit rapide."""
    import yt_dlp  # noqa: F401
    import gibvid_jsc  # noqa: F401
    return json.dumps({'version': _active_version()})


def _journal(message):
    """Journal des 200 derniers Ko dans Caches/gibvid.log, récupérable depuis le Mac pour déboguer."""
    print(message)
    try:
        path = os.path.join(_paths['caches'], 'gibvid.log')
        if os.path.exists(path) and os.path.getsize(path) > 200_000:
            os.replace(path, path + '.1')
        with open(path, 'a', encoding='utf-8') as f:
            f.write(f'{time.strftime("%Y-%m-%d %H:%M:%S")} {message}\n')
    except OSError:
        pass


class _Logger:
    def __init__(self):
        self.errors = []

    def debug(self, msg):
        pass

    def info(self, msg):
        pass

    def warning(self, msg):
        _journal(f'[yt-dlp] {msg}')

    def error(self, msg):
        _journal(f'[yt-dlp] {msg}')
        self.errors.append(msg)


def _emit(**event):
    _gibvid.progress(json.dumps(event))


def _check_cancelled():
    if _gibvid.cancelled():
        from yt_dlp.utils import DownloadCancelled
        raise DownloadCancelled()


def _entries(info):
    if info.get('_type') in ('playlist', 'multi_video'):
        for entry in info.get('entries') or []:
            if entry:
                yield from _entries(entry)
    else:
        yield info


def _has_video(fmt):
    return fmt.get('vcodec') != 'none' or fmt.get('ext') in ('mp4', 'mov', 'm4v', 'webm')


_TWITTER_MEDIA_URL = re.compile(
    r'^(https?://(?:(?:www|mobile)\.)?(?:twitter|x)\.com/(?:i/web|[^/]+)/status/\d+)/(?:video|photo)/(\d+)')


def _extract(ydl, url):
    """extract_info, plus un contournement pour les GIF de X/Twitter.

    Pour un lien de partage « …/status/<id>/video/1 », yt-dlp refuse tout média
    dont le type n'est pas « video » ; or X classe les GIF en « animated_gif »
    (« Media #1 is not a video »). Sans le numéro de média, yt-dlp les récupère
    bien (en MP4 H.264 sans son) : on réessaie donc sans, puis on garde le média visé.
    """
    from yt_dlp.utils import DownloadError
    try:
        return ydl.extract_info(url, download=False)
    except DownloadError as e:
        match = _TWITTER_MEDIA_URL.match(url)
        if not match or 'is not a video' not in str(e):
            raise
    _journal('↻ GIF X/Twitter : nouvelle tentative sans le numéro de média')
    _check_cancelled()
    info = ydl.extract_info(match.group(1), download=False)
    entries = list(_entries(info))
    index = int(match.group(2)) - 1
    return entries[index] if len(entries) > 1 and index < len(entries) else info


def download(payload):
    request = json.loads(payload)
    url, outdir = request['url'], request['outdir']
    logger = _Logger()
    _journal(f'→ {url}')
    try:
        import yt_dlp
        import gibvid_jsc  # noqa: F401  (enregistre le solveur JavaScriptCore)

        os.makedirs(outdir, exist_ok=True)
        _emit(phase='analyzing')

        progress = {'index': 0, 'count': 1, 'last': 0.0}

        def hook(d):
            _check_cancelled()
            if d.get('status') != 'downloading':
                return
            now = time.monotonic()
            if now - progress['last'] < 0.1:
                return
            progress['last'] = now
            total = d.get('total_bytes') or d.get('total_bytes_estimate')
            if total:
                fraction = min(d.get('downloaded_bytes', 0) / total, 1.0)
            elif d.get('fragment_count'):
                fraction = (d.get('fragment_index') or 0) / d['fragment_count']
            else:
                fraction = 0.0
            _emit(phase='downloading', fraction=(progress['index'] + fraction) / progress['count'])

        options = {
            'format': _FORMAT,
            'format_sort': ['proto:https'],
            'noplaylist': True,
            'playlistend': _MAX_ITEMS,
            'quiet': True,
            'noprogress': True,
            'logger': logger,
            'progress_hooks': [hook],
            'cachedir': os.path.join(_paths['caches'], 'yt-dlp'),
            'retries': 3,
            'fragment_retries': 5,
            'concurrent_fragment_downloads': 4,
            'http_chunk_size': 10 * 1024 * 1024,
            'socket_timeout': 20,
            'js_runtimes': {},
        }

        with yt_dlp.YoutubeDL(options) as ydl:
            info = _extract(ydl, url)
            _check_cancelled()
            entries = [e for e in _entries(info) if any(_has_video(f) for f in e.get('requested_formats') or [e])]
            if not entries:
                return json.dumps({'ok': False, 'error': 'Aucune vidéo trouvée à ce lien.'})

            downloads = [(entry, fmt) for entry in entries[:_MAX_ITEMS] for fmt in entry.get('requested_formats') or [entry]]
            progress['count'] = len(downloads)
            items, files = [], {}
            for index, (entry, fmt) in enumerate(downloads):
                progress['index'] = index
                job = dict(entry)
                job.pop('requested_formats', None)
                job.update(fmt)
                ext = job.get('ext') if job.get('ext') in _KNOWN_EXTS else 'mp4'
                path = os.path.join(outdir, f'{index:02d}-{job.get("format_id") or "media"}.{ext}'.replace('/', '_'))
                success, _ = ydl.dl(path, job)
                _check_cancelled()
                if not success:
                    raise yt_dlp.utils.DownloadError(logger.errors[-1] if logger.errors else 'Téléchargement interrompu')
                try:
                    gibvid_mp4.defragment(path)
                except Exception:
                    traceback.print_exc()  # on tente quand même avec le fichier d'origine
                files.setdefault(id(entry), []).append(path)

            for entry in entries[:_MAX_ITEMS]:
                items.append({'title': entry.get('title') or '', 'files': files[id(entry)]})

        _journal(f'✓ {len(items)} vidéo(s) : ' + ', '.join(os.path.basename(p) for item in items for p in item['files']))
        return json.dumps({'ok': True, 'items': items})
    except Exception as e:
        # yt-dlp peut emballer l'annulation dans une autre exception.
        if _gibvid.cancelled():
            return json.dumps({'ok': False, 'cancelled': True})
        _journal('✗ ' + traceback.format_exc())
        return json.dumps({'ok': False, 'error': _friendly_error(str(e) or repr(e))})


_ERRORS = [
    (r'Unsupported URL', 'Ce lien n’est pas pris en charge.'),
    (r'[Pp]rivate (video|account)|This account is private', 'Ce contenu est privé.'),
    (r'login required|[Ss]ign in to confirm|--cookies|log ?in', 'Ce contenu demande d’être connecté au site.'),
    (r'not available in your country|geo.?restrict', 'Ce contenu n’est pas disponible dans ton pays.'),
    (r'removed|deleted|no longer available|does not exist|HTTP Error 404', 'Ce contenu n’existe plus.'),
    (r'live event|is live|premieres in', 'Les directs ne sont pas pris en charge.'),
    (r'Unable to download webpage|Connection|timed out|Network is unreachable|Temporary failure', 'Connexion impossible. Vérifie ton réseau.'),
    (r'Requested format is not available|No video formats', 'Aucun format vidéo compatible trouvé.'),
    (r'No video could be found|is not a video', 'Aucune vidéo ni GIF trouvé à ce lien.'),
]


def _friendly_error(message):
    message = re.sub(r'^ERROR:\s*', '', message.strip())
    for pattern, friendly in _ERRORS:
        if re.search(pattern, message):
            return friendly
    return message.split('\n')[0][:200]

# endregion
