#ifndef GIB_BRIDGE_H
#define GIB_BRIDGE_H

#include <stdbool.h>

// Pont minimal entre Swift et l'interpréteur Python embarqué.
// Toutes les chaînes renvoyées sont allouées avec malloc : les libérer avec free().

/// Exécute un script JavaScript ; renvoie ce que le script a écrit avec console.log.
typedef char *_Nullable (*GibRunJSFn)(const char *_Nonnull script, bool *_Nonnull ok);
/// Reçoit un évènement de progression JSON émis par Python.
typedef void (*GibProgressFn)(const char *_Nonnull json);

void gib_set_callbacks(GibRunJSFn _Nonnull run_js, GibProgressFn _Nonnull progress);
void gib_set_cancelled(bool cancelled);

/// Démarre l'interpréteur. Renvoie NULL si tout va bien, sinon un message d'erreur.
char *_Nullable gib_python_start(const char *_Nonnull python_home,
                                 const char *_Nonnull app_path,
                                 const char *_Nonnull pycache_prefix);

/// Appelle gibvid.<function>(argument) et renvoie le résultat (NULL si exception Python).
char *_Nullable gib_python_call(const char *_Nonnull function, const char *_Nonnull argument);

#endif
