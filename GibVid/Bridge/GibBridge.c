#include "GibBridge.h"

#include <Python/Python.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

static GibRunJSFn gib_run_js;
static GibProgressFn gib_progress;
static atomic_bool gib_cancelled;

void gib_set_callbacks(GibRunJSFn run_js, GibProgressFn progress) {
    gib_run_js = run_js;
    gib_progress = progress;
}

void gib_set_cancelled(bool cancelled) {
    atomic_store(&gib_cancelled, cancelled);
}

// region: module _gibvid (Python → Swift)

static PyObject *gibvid_run_js(PyObject *self, PyObject *args) {
    const char *script;
    if (!PyArg_ParseTuple(args, "s", &script)) return NULL;

    char *output = NULL;
    bool ok = false;
    // Le JS peut prendre plusieurs secondes : on libère le GIL pendant ce temps.
    Py_BEGIN_ALLOW_THREADS
    output = gib_run_js(script, &ok);
    Py_END_ALLOW_THREADS

    PyObject *result = Py_BuildValue("(Os)", ok ? Py_True : Py_False, output ? output : "");
    free(output);
    return result;
}

static PyObject *gibvid_progress(PyObject *self, PyObject *args) {
    const char *json;
    if (!PyArg_ParseTuple(args, "s", &json)) return NULL;
    gib_progress(json);
    Py_RETURN_NONE;
}

static PyObject *gibvid_cancelled(PyObject *self, PyObject *args) {
    return PyBool_FromLong(atomic_load(&gib_cancelled));
}

static PyMethodDef gibvid_methods[] = {
    {"run_js", gibvid_run_js, METH_VARARGS, "Exécute du JavaScript avec JavaScriptCore."},
    {"progress", gibvid_progress, METH_VARARGS, "Transmet un évènement de progression à Swift."},
    {"cancelled", gibvid_cancelled, METH_NOARGS, "Indique si l'utilisateur a annulé."},
    {NULL, NULL, 0, NULL},
};

static struct PyModuleDef gibvid_module = {
    PyModuleDef_HEAD_INIT, "_gibvid", NULL, -1, gibvid_methods,
};

static PyObject *PyInit__gibvid(void) {
    return PyModule_Create(&gibvid_module);
}

// endregion

static char *gib_status_error(const char *step, PyStatus status) {
    char *message = NULL;
    asprintf(&message, "%s : %s", step, status.err_msg ? status.err_msg : "erreur inconnue");
    return message;
}

static char *gib_fetch_exception(void) {
    PyObject *exception = PyErr_GetRaisedException();
    if (!exception) return strdup("erreur Python inconnue");
    PyObject *text = PyObject_Str(exception);
    const char *utf8 = text ? PyUnicode_AsUTF8(text) : NULL;
    char *message = strdup(utf8 ? utf8 : "erreur Python illisible");
    PyErr_SetRaisedException(exception);
    PyErr_Print();
    Py_XDECREF(text);
    return message;
}

char *gib_python_start(const char *python_home, const char *app_path, const char *pycache_prefix) {
    if (PyImport_AppendInittab("_gibvid", PyInit__gibvid) == -1) {
        return strdup("Impossible d'enregistrer le module _gibvid");
    }

    PyPreConfig preconfig;
    PyPreConfig_InitIsolatedConfig(&preconfig);
    preconfig.utf8_mode = 1;
    PyStatus status = Py_PreInitialize(&preconfig);
    if (PyStatus_Exception(status)) return gib_status_error("Pré-initialisation", status);

    PyConfig config;
    PyConfig_InitIsolatedConfig(&config);
    config.use_system_logger = 1;  // print() → journal système (Console.app)
    config.buffered_stdio = 0;
    config.install_signal_handlers = 0;

    status = PyConfig_SetBytesString(&config, &config.home, python_home);
    if (!PyStatus_Exception(status)) {
        // Le bundle est en lecture seule : les .pyc vont dans Caches.
        status = PyConfig_SetBytesString(&config, &config.pycache_prefix, pycache_prefix);
    }
    if (!PyStatus_Exception(status)) status = Py_InitializeFromConfig(&config);
    PyConfig_Clear(&config);
    if (PyStatus_Exception(status)) return gib_status_error("Initialisation", status);

    PyObject *sys_path = PySys_GetObject("path");  // référence empruntée
    PyObject *app = PyUnicode_FromString(app_path);
    if (!sys_path || !app || PyList_Insert(sys_path, 0, app) == -1) {
        Py_XDECREF(app);
        char *message = gib_fetch_exception();
        PyEval_SaveThread();
        return message;
    }
    Py_DECREF(app);

    // Rend le GIL : chaque appel le reprend avec PyGILState_Ensure.
    PyEval_SaveThread();
    return NULL;
}

char *gib_python_call(const char *function, const char *argument) {
    PyGILState_STATE gil = PyGILState_Ensure();
    char *output = NULL;

    PyObject *module = PyImport_ImportModule("gibvid");
    PyObject *result = module ? PyObject_CallMethod(module, function, "s", argument) : NULL;
    const char *utf8 = result ? PyUnicode_AsUTF8(result) : NULL;
    if (utf8) {
        output = strdup(utf8);
    } else {
        free(gib_fetch_exception());
    }

    Py_XDECREF(result);
    Py_XDECREF(module);
    PyGILState_Release(gil);
    return output;
}
