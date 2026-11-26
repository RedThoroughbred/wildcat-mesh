// Wildcat Mesh: the embedded CPython that runs the Reticulum stack.
// Copyright (C) 2026 Seth Egger. GPL-3.0-or-later.
//
// Interpreter setup follows BeeWare's iOS testbed (Python-Apple-support): an isolated
// configuration, the bundled standard library as home, app_packages added with site.addsitedir.
#define PY_SSIZE_T_CLEAN
#include <Python.h>  // HEADER_SEARCH_PATHS: $(BUILT_PRODUCTS_DIR)/Python.framework/Headers

#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "WildcatPython.h"

static wc_event_fn event_handler;
static wc_bytes_fn write_handler;
static atomic_int bridge_running;
static atomic_int rnode_connected;
static PyObject *bridge_module;

static pthread_mutex_t rx_lock = PTHREAD_MUTEX_INITIALIZER;
static uint8_t *rx_buf;
static size_t rx_len, rx_cap;
/// More than this waiting means Reticulum stopped reading: drop the oldest (the RNode's own
/// queue is smaller than this).
static const size_t rx_limit = 256 * 1024;

void wc_set_handlers(wc_event_fn on_event, wc_bytes_fn on_rnode_write) {
    event_handler = on_event;
    write_handler = on_rnode_write;
}

/// An error event with `message`, JSON-escaped.
static void emit_error(const char *message) {
    if (!event_handler) return;
    char escaped[512];
    size_t j = 0;
    for (size_t i = 0; message[i] && j < sizeof(escaped) - 3; i++) {
        unsigned char c = (unsigned char)message[i];
        if (c == '"' || c == '\\') { escaped[j++] = '\\'; escaped[j++] = (char)c; }
        else if (c < 0x20) { escaped[j++] = ' '; }
        else { escaped[j++] = (char)c; }
    }
    escaped[j] = 0;
    char json[600];
    snprintf(json, sizeof(json), "{\"event\": \"error\", \"message\": \"%s\"}", escaped);
    event_handler(json);
}

/// The current Python exception as an error event (and cleared).
static void emit_python_error(const char *context) {
    PyObject *exc = PyErr_GetRaisedException();
    char message[400];
    const char *text = "unknown error";
    PyObject *str = exc ? PyObject_Str(exc) : NULL;
    if (str) text = PyUnicode_AsUTF8(str);
    snprintf(message, sizeof(message), "%s: %s", context, text ? text : "?");
    Py_XDECREF(str);
    Py_XDECREF(exc);
    PyErr_Clear();
    emit_error(message);
}

// MARK: - The _wildcat module (what the bridge imports)

static PyObject *py_emit(PyObject *self, PyObject *args) {
    const char *json;
    if (!PyArg_ParseTuple(args, "s", &json)) return NULL;
    if (event_handler) event_handler(json);
    Py_RETURN_NONE;
}

static PyObject *py_rnode_connected(PyObject *self, PyObject *unused) {
    return PyBool_FromLong(atomic_load(&rnode_connected));
}

static PyObject *py_rnode_available(PyObject *self, PyObject *unused) {
    pthread_mutex_lock(&rx_lock);
    size_t n = rx_len;
    pthread_mutex_unlock(&rx_lock);
    return PyLong_FromSize_t(n);
}

static PyObject *py_rnode_read(PyObject *self, PyObject *args) {
    Py_ssize_t want;
    if (!PyArg_ParseTuple(args, "n", &want)) return NULL;
    if (want < 0) want = 0;
    pthread_mutex_lock(&rx_lock);
    size_t take = (size_t)want < rx_len ? (size_t)want : rx_len;
    PyObject *bytes = PyBytes_FromStringAndSize((const char *)rx_buf, (Py_ssize_t)take);
    if (bytes && take > 0) {
        memmove(rx_buf, rx_buf + take, rx_len - take);
        rx_len -= take;
    }
    pthread_mutex_unlock(&rx_lock);
    return bytes;
}

static PyObject *py_rnode_write(PyObject *self, PyObject *args) {
    Py_buffer buf;
    if (!PyArg_ParseTuple(args, "y*", &buf)) return NULL;
    Py_ssize_t written = 0;
    if (atomic_load(&rnode_connected) && write_handler && buf.len > 0) {
        write_handler((const uint8_t *)buf.buf, (size_t)buf.len);
        written = buf.len;
    }
    PyBuffer_Release(&buf);
    return PyLong_FromSsize_t(written);
}

static PyObject *py_rnode_reset(PyObject *self, PyObject *unused) {
    pthread_mutex_lock(&rx_lock);
    rx_len = 0;
    pthread_mutex_unlock(&rx_lock);
    Py_RETURN_NONE;
}

static PyMethodDef wildcat_methods[] = {
    {"emit", py_emit, METH_VARARGS, "Send an event (a JSON string) to the app."},
    {"rnode_connected", py_rnode_connected, METH_NOARGS, "The RNode's Bluetooth link is up and handed to Reticulum."},
    {"rnode_available", py_rnode_available, METH_NOARGS, "Bytes from the RNode waiting to be read."},
    {"rnode_read", py_rnode_read, METH_VARARGS, "Read up to n bytes from the RNode."},
    {"rnode_write", py_rnode_write, METH_VARARGS, "Write bytes to the RNode; returns how many were taken."},
    {"rnode_reset", py_rnode_reset, METH_NOARGS, "Drop bytes waiting from the RNode."},
    {NULL, NULL, 0, NULL},
};

static struct PyModuleDef wildcat_module = {
    PyModuleDef_HEAD_INIT, "_wildcat", "Wildcat's app side of the Reticulum bridge.", -1, wildcat_methods,
};

static PyObject *PyInit__wildcat(void) { return PyModule_Create(&wildcat_module); }

// MARK: - Starting Python

int wc_python_run(const char *python_home, const char *app_packages, const char *app_path) {
    PyStatus status;
    PyPreConfig preconfig;
    PyConfig config;

    if (PyImport_AppendInittab("_wildcat", PyInit__wildcat) != 0) {
        emit_error("Couldn't register the _wildcat module");
        return -1;
    }

    PyPreConfig_InitIsolatedConfig(&preconfig);
    preconfig.utf8_mode = 1;
    status = Py_PreInitialize(&preconfig);
    if (PyStatus_Exception(status)) { emit_error(status.err_msg ? status.err_msg : "Py_PreInitialize failed"); return -1; }

    PyConfig_InitIsolatedConfig(&config);
    // The app bundle is signed and read-only: no .pyc files written next to the sources.
    config.write_bytecode = 0;
    config.buffered_stdio = 0;
    // The app owns the process's signals. (RNS and LXMF still install SIGINT/SIGTERM handlers for
    // themselves through the signal module when they start.)
    config.install_signal_handlers = 0;
    status = PyConfig_SetBytesString(&config, &config.home, python_home);
    if (PyStatus_Exception(status)) { emit_error("Couldn't set the Python home"); PyConfig_Clear(&config); return -1; }
    status = PyConfig_Read(&config);
    if (PyStatus_Exception(status)) { emit_error(status.err_msg ? status.err_msg : "PyConfig_Read failed"); PyConfig_Clear(&config); return -1; }
    status = Py_InitializeFromConfig(&config);
    PyConfig_Clear(&config);
    if (PyStatus_Exception(status)) { emit_error(status.err_msg ? status.err_msg : "Py_InitializeFromConfig failed"); return -1; }

    // app_packages: rns, LXMF, serial, cryptography, cffi. A site directory, so .pth files apply.
    PyObject *site = PyImport_ImportModule("site");
    PyObject *added = site ? PyObject_CallMethod(site, "addsitedir", "s", app_packages) : NULL;
    if (!added) { emit_python_error("site.addsitedir"); Py_XDECREF(site); return -2; }
    Py_DECREF(added);
    Py_DECREF(site);

    // The app's own Python (the bridge and the RNode interface) first on sys.path.
    PyObject *path = PySys_GetObject("path");  // borrowed
    PyObject *app = PyUnicode_FromString(app_path);
    if (!path || !app || PyList_Insert(path, 0, app) != 0) { emit_python_error("sys.path"); Py_XDECREF(app); return -2; }
    Py_DECREF(app);

    bridge_module = PyImport_ImportModule("wildcat_reticulum");
    if (!bridge_module) { emit_python_error("import wildcat_reticulum"); return -3; }

    atomic_store(&bridge_running, 1);
    // The bridge's command loop: this thread is Python's main thread from here on. Python releases
    // the GIL while the loop waits, so Reticulum's threads and wc_python_submit get their turns.
    PyObject *result = PyObject_CallMethod(bridge_module, "main", NULL);
    atomic_store(&bridge_running, 0);
    if (!result) { emit_python_error("bridge"); return -4; }
    Py_DECREF(result);
    // The interpreter stays up: Reticulum's daemon threads may still hold references.
    return 0;
}

int wc_python_submit(const char *json) {
    if (!atomic_load(&bridge_running) || !bridge_module) return -1;
    PyGILState_STATE gil = PyGILState_Ensure();
    PyObject *result = PyObject_CallMethod(bridge_module, "submit", "s", json);
    int rc = 0;
    if (!result) { emit_python_error("submit"); rc = -2; }
    else Py_DECREF(result);
    PyGILState_Release(gil);
    return rc;
}

// MARK: - The RNode pipe (Swift side)

void wc_rnode_set_connected(int connected) {
    atomic_store(&rnode_connected, connected ? 1 : 0);
    if (!connected) {
        pthread_mutex_lock(&rx_lock);
        rx_len = 0;
        pthread_mutex_unlock(&rx_lock);
    }
}

void wc_rnode_push(const uint8_t *bytes, size_t length) {
    if (!bytes || length == 0) return;
    pthread_mutex_lock(&rx_lock);
    if (rx_len + length > rx_limit) {
        size_t drop = rx_len + length - rx_limit;
        if (drop > rx_len) drop = rx_len;
        memmove(rx_buf, rx_buf + drop, rx_len - drop);
        rx_len -= drop;
    }
    if (rx_len + length > rx_cap) {
        size_t cap = rx_cap ? rx_cap : 4096;
        while (cap < rx_len + length) cap *= 2;
        uint8_t *grown = realloc(rx_buf, cap);
        if (!grown) { pthread_mutex_unlock(&rx_lock); return; }
        rx_buf = grown;
        rx_cap = cap;
    }
    memcpy(rx_buf + rx_len, bytes, length);
    rx_len += length;
    pthread_mutex_unlock(&rx_lock);
}

size_t wc_rnode_pending(void) {
    pthread_mutex_lock(&rx_lock);
    size_t n = rx_len;
    pthread_mutex_unlock(&rx_lock);
    return n;
}
