"""Solveur des défis JavaScript de YouTube, exécuté par JavaScriptCore.

yt-dlp a besoin d'un moteur JS (deno, node…) pour déchiffrer les URL des
vidéos YouTube. Sur iPhone on n'a pas de processus externes, mais on a
JavaScriptCore : ce fournisseur réutilise les scripts officiels yt-dlp-ejs et
délègue leur exécution à Swift via `_gibvid.run_js`.
"""
from yt_dlp.extractor.youtube.jsc._builtin.ejs import EJSBaseJCP
from yt_dlp.extractor.youtube.jsc.provider import (
    JsChallengeProviderError,
    register_preference,
    register_provider,
)

import _gibvid


@register_provider
class JavaScriptCoreJCP(EJSBaseJCP):
    PROVIDER_VERSION = '1.0.0'
    JS_RUNTIME_NAME = 'javascriptcore'
    BUG_REPORT_LOCATION = 'Gib Vid'

    def is_available(self, /) -> bool:
        return self._available

    def _run_js_runtime(self, stdin: str, /) -> str:
        ok, output = _gibvid.run_js(stdin)
        if not ok:
            raise JsChallengeProviderError(f'JavaScriptCore: {output}')
        return output


@register_preference(JavaScriptCoreJCP)
def preference(provider, requests) -> int:
    return 1000
