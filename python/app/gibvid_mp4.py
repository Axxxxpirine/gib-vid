"""Conversion des MP4 fragmentés (DASH) en MP4 classiques, sans réencodage.

YouTube, Instagram & co. servent la vidéo et l'audio en MP4 fragmentés.
AVFoundation les lit mal (chaque échantillon dure deux fois trop longtemps) et,
sans ffmpeg sur iPhone, on ne peut pas les « remuxer ». Ce module fait le
travail d'un `ffmpeg -c copy` pour le cas simple d'une seule piste : il lit
les tables des fragments (moof/traf/trun), reconstruit une table d'échantillons
classique (stbl) et réécrit les données dans un seul mdat.
"""
import os
import struct

_CONTAINERS = {b'moov', b'trak', b'edts', b'mdia', b'minf'}
_COPY_BLOCK = 4 * 1024 * 1024


def _read_boxes(f, start, end):
    """Itère sur les boîtes entre start et end : (type, début, taille, taille d'en-tête)."""
    offset = start
    while offset + 8 <= end:
        f.seek(offset)
        size, kind = struct.unpack('>I4s', f.read(8))
        header = 8
        if size == 1:
            size = struct.unpack('>Q', f.read(8))[0]
            header = 16
        elif size == 0:
            size = end - offset
        if size < header or offset + size > end:
            raise ValueError(f'boîte {kind!r} invalide')
        yield kind, offset, size, header
        offset += size


def _parse_boxes(data):
    offset = 0
    while offset + 8 <= len(data):
        size, kind = struct.unpack_from('>I4s', data, offset)
        header = 8
        if size == 1:
            size = struct.unpack_from('>Q', data, offset + 8)[0]
            header = 16
        elif size == 0:
            size = len(data) - offset
        if size < header:
            raise ValueError(f'boîte {kind!r} invalide')
        yield kind, data[offset + header:offset + size]
        offset += size


def _box(kind, payload):
    return struct.pack('>I4s', 8 + len(payload), kind) + payload


def _full_box(kind, version, flags, payload):
    return _box(kind, struct.pack('>I', (version << 24) | flags) + payload)


def _find(data, *path):
    for kind, payload in _parse_boxes(data):
        if kind == path[0]:
            return payload if len(path) == 1 else _find(payload, *path[1:])
    return None


# region: lecture des fragments

def _trex_defaults(moov):
    trex = _find(moov, b'mvex', b'trex')
    if trex is None:
        return 0, 0, 0
    _, _, _, duration, size, flags = struct.unpack_from('>IIIIII', trex, 0)
    return duration, size, flags


def _read_samples(f, moof_offset, moof, defaults):
    """Renvoie les runs d'échantillons d'un moof : [[(offset, taille, durée, flags, cto), …], …]."""
    runs = []
    for kind, traf in _parse_boxes(moof):
        if kind != b'traf':
            continue
        tfhd = _find(traf, b'tfhd')
        tf_flags = struct.unpack_from('>I', tfhd, 0)[0] & 0xFFFFFF
        position = 8  # version/flags + track_ID
        base = moof_offset
        if tf_flags & 0x1:
            base = struct.unpack_from('>Q', tfhd, position)[0]
            position += 8
        if tf_flags & 0x2:
            position += 4
        default_duration, default_size, default_flags = defaults
        if tf_flags & 0x8:
            default_duration = struct.unpack_from('>I', tfhd, position)[0]
            position += 4
        if tf_flags & 0x10:
            default_size = struct.unpack_from('>I', tfhd, position)[0]
            position += 4
        if tf_flags & 0x20:
            default_flags = struct.unpack_from('>I', tfhd, position)[0]

        data_end = base
        for kind, trun in _parse_boxes(traf):
            if kind != b'trun':
                continue
            header = struct.unpack_from('>I', trun, 0)[0]
            version, flags = header >> 24, header & 0xFFFFFF
            count = struct.unpack_from('>I', trun, 4)[0]
            position = 8
            offset = data_end
            if flags & 0x1:
                offset = base + struct.unpack_from('>i', trun, position)[0]
                position += 4
            first_flags = None
            if flags & 0x4:
                first_flags = struct.unpack_from('>I', trun, position)[0]
                position += 4

            samples = []
            for index in range(count):
                duration, size, sample_flags, cto = default_duration, default_size, default_flags, 0
                if flags & 0x100:
                    duration = struct.unpack_from('>I', trun, position)[0]
                    position += 4
                if flags & 0x200:
                    size = struct.unpack_from('>I', trun, position)[0]
                    position += 4
                if flags & 0x400:
                    sample_flags = struct.unpack_from('>I', trun, position)[0]
                    position += 4
                elif index == 0 and first_flags is not None:
                    sample_flags = first_flags
                if flags & 0x800:
                    cto = struct.unpack_from('>i' if version else '>I', trun, position)[0]
                    position += 4
                samples.append((offset, size, duration, sample_flags, cto))
                offset += size
            data_end = offset
            if samples:
                runs.append(samples)
    return runs

# endregion


# region: reconstruction de la table d'échantillons

def _run_length(values):
    entries = []
    for value in values:
        if entries and entries[-1][1] == value:
            entries[-1][0] += 1
        else:
            entries.append([1, value])
    return entries


def _build_stbl(stbl, runs, chunk_offsets):
    samples = [sample for run in runs for sample in run]
    sizes = [s[1] for s in samples]
    durations = [s[2] for s in samples]
    ctos = [s[4] for s in samples]
    # sample_is_non_sync_sample (bit 16) à 0 → image clé
    syncs = [i + 1 for i, s in enumerate(samples) if not (s[3] >> 16) & 1]

    children = [_box(b'stsd', _find(stbl, b'stsd'))]
    stts = _run_length(durations)
    children.append(_full_box(b'stts', 0, 0, struct.pack('>I', len(stts)) + b''.join(struct.pack('>II', n, d) for n, d in stts)))
    if any(ctos):
        negative = any(c < 0 for c in ctos)
        ctts = _run_length(ctos)
        children.append(_full_box(b'ctts', 1 if negative else 0, 0, struct.pack('>I', len(ctts)) + b''.join(
            struct.pack('>Ii' if negative else '>II', n, c) for n, c in ctts)))
    if len(syncs) != len(samples):
        children.append(_full_box(b'stss', 0, 0, struct.pack('>I', len(syncs)) + b''.join(struct.pack('>I', i) for i in syncs)))
    stsc = []
    for chunk, run in enumerate(runs, 1):
        if not stsc or stsc[-1][1] != len(run):
            stsc.append((chunk, len(run)))
    children.append(_full_box(b'stsc', 0, 0, struct.pack('>I', len(stsc)) + b''.join(struct.pack('>III', c, n, 1) for c, n in stsc)))
    children.append(_full_box(b'stsz', 0, 0, struct.pack('>II', 0, len(sizes)) + b''.join(struct.pack('>I', s) for s in sizes)))
    children.append(_full_box(b'co64', 0, 0, struct.pack('>I', len(chunk_offsets)) + b''.join(struct.pack('>Q', o) for o in chunk_offsets)))
    return _box(b'stbl', b''.join(children))


def _with_duration(kind, payload, duration):
    """Réécrit le champ durée de mvhd / tkhd / mdhd."""
    version = payload[0]
    position = {b'mvhd': (16, 24), b'mdhd': (16, 24), b'tkhd': (20, 28)}[kind][version]
    data = bytearray(payload)
    if version == 1:
        struct.pack_into('>Q', data, position, duration)
    else:
        struct.pack_into('>I', data, position, min(duration, 0xFFFFFFFF))
    return bytes(data)


def _with_edit_durations(payload, movie_duration, media_timescale, movie_timescale):
    """En fragmenté, les segments de la liste d'édition ont souvent une durée nulle
    (« jusqu'à la fin ») ; dans un MP4 classique ça voudrait dire « rien ». On les complète."""
    version = payload[0]
    count = struct.unpack_from('>I', payload, 4)[0]
    entry = '>Qq' if version == 1 else '>Ii'
    width = struct.calcsize(entry) + 4  # + media_rate
    data = bytearray(payload)
    for index in range(count):
        position = 8 + index * width
        duration, media_time = struct.unpack_from(entry, data, position)
        if duration == 0 and media_time >= 0:
            remaining = movie_duration - media_time * movie_timescale // media_timescale
            struct.pack_into(entry, data, position, max(remaining, 0), media_time)
    return bytes(data)


def _rebuild(kind, payload, stbl, media_duration, movie_duration, timescales):
    if kind == b'stbl':
        return stbl
    if kind == b'elst':
        return _box(kind, _with_edit_durations(payload, movie_duration, *timescales))
    if kind == b'mvex':
        return b''
    if kind == b'mvhd':
        return _box(kind, _with_duration(kind, payload, movie_duration))
    if kind == b'tkhd':
        return _box(kind, _with_duration(kind, payload, movie_duration))
    if kind == b'mdhd':
        return _box(kind, _with_duration(kind, payload, media_duration))
    if kind in _CONTAINERS:
        return _box(kind, b''.join(
            _rebuild(k, p, stbl, media_duration, movie_duration, timescales) for k, p in _parse_boxes(payload)))
    return _box(kind, payload)

# endregion


def defragment(path):
    """Convertit sur place un MP4 fragmenté à une piste en MP4 classique. Renvoie True si converti."""
    with open(path, 'rb') as f:
        f.seek(0, 2)
        end = f.tell()
        top = list(_read_boxes(f, 0, end))
        if not any(kind == b'moof' for kind, *_ in top):
            return False

        ftyp = moov = None
        runs = []
        defaults = None
        for kind, offset, size, header in top:
            if kind in (b'ftyp', b'moov'):
                f.seek(offset + header)
                payload = f.read(size - header)
                if kind == b'ftyp':
                    ftyp = payload
                else:
                    moov = payload
                    defaults = _trex_defaults(moov)
            elif kind == b'moof' and moov is not None:
                f.seek(offset + header)
                runs.extend(_read_samples(f, offset, f.read(size - header), defaults))

        if moov is None or not runs:
            return False
        if sum(1 for kind, _ in _parse_boxes(moov) if kind == b'trak') != 1:
            return False  # plusieurs pistes : cas non géré, on laisse tel quel

        stbl = _find(moov, b'trak', b'mdia', b'minf', b'stbl')
        mdhd = _find(moov, b'trak', b'mdia', b'mdhd')
        mvhd = _find(moov, b'mvhd')
        media_timescale = struct.unpack_from('>I', mdhd, 20 if mdhd[0] == 1 else 12)[0]
        movie_timescale = struct.unpack_from('>I', mvhd, 20 if mvhd[0] == 1 else 12)[0]
        media_duration = sum(sample[2] for run in runs for sample in run)
        movie_duration = media_duration * movie_timescale // media_timescale

        # La taille du moov ne dépend pas des offsets (co64 à 8 octets) : on la calcule
        # une première fois avec des offsets fictifs, puis on place les données après.
        ftyp_box = _box(b'ftyp', ftyp) if ftyp is not None else b''
        timescales = (media_timescale, movie_timescale)
        placeholder = _rebuild(b'moov', moov, _build_stbl(stbl, runs, [0] * len(runs)), media_duration, movie_duration, timescales)
        data_size = sum(sample[1] for run in runs for sample in run)
        mdat_header = struct.pack('>I4sQ', 1, b'mdat', 16 + data_size) if data_size + 8 > 0xFFFFFFFF \
            else struct.pack('>I4s', 8 + data_size, b'mdat')
        position = len(ftyp_box) + len(placeholder) + len(mdat_header)
        chunk_offsets = []
        for run in runs:
            chunk_offsets.append(position)
            position += sum(sample[1] for sample in run)
        moov_box = _rebuild(b'moov', moov, _build_stbl(stbl, runs, chunk_offsets), media_duration, movie_duration, timescales)

        temporary = path + '.defrag'
        with open(temporary, 'wb') as out:
            out.write(ftyp_box)
            out.write(moov_box)
            out.write(mdat_header)
            for run in runs:
                # Les échantillons d'un run sont contigus : une seule lecture par run.
                start = run[0][0]
                remaining = sum(sample[1] for sample in run)
                f.seek(start)
                while remaining:
                    block = f.read(min(remaining, _COPY_BLOCK))
                    if not block:
                        raise ValueError('fichier tronqué')
                    out.write(block)
                    remaining -= len(block)

    os.replace(temporary, path)
    return True
