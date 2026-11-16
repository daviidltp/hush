/*
 * Argon2 reference source code package - reference C implementations
 *
 * Copyright 2015
 * Daniel Dinu, Dmitry Khovratovich, Jean-Philippe Aumasson, and Samuel Neves
 *
 * You may use this work under the terms of a Creative Commons CC0 1.0
 * License/Waiver or the Apache Public License 2.0, at your option. The terms of
 * these licenses can be found at:
 *
 * - CC0 1.0 Universal : https://creativecommons.org/publicdomain/zero/1.0
 * - Apache 2.0        : https://www.apache.org/licenses/LICENSE-2.0
 *
 * You should have received a copy of both of these licenses along with this
 * software. If not, they may be obtained at the above URLs.
 */

#if !defined(ARGON2_NO_THREADS)

#include "thread.h"
#if defined(__APPLE__)
#include <pthread/qos.h>
#endif
#if defined(_WIN32)
#include <windows.h>
#endif

int argon2_thread_create(argon2_thread_handle_t *handle,
                         argon2_thread_func_t func, void *args) {
    if (NULL == handle || func == NULL) {
        return -1;
    }
#if defined(_WIN32)
    *handle = _beginthreadex(NULL, 0, func, args, 0, NULL);
    return *handle != 0 ? 0 : -1;
#else
#if defined(__APPLE__)
    /* Parche Hush: en macOS un hilo nuevo no hereda la prioridad (QoS) de quien lo crea y queda en
     * «default», así que con el Mac ocupado las pasadas van a los núcleos lentos y el descifrado tarda
     * bastante más. Si quien llama tiene a alguien esperando (user-initiated o más), los hilos van a la
     * prioridad más alta; si no, heredan la de quien llama. */
    {
        qos_class_t caller = qos_class_self();
        qos_class_t qos = caller >= QOS_CLASS_USER_INITIATED ? QOS_CLASS_USER_INTERACTIVE : caller;
        pthread_attr_t attr;
        int result;
        if (pthread_attr_init(&attr) != 0) {
            return -1;
        }
        pthread_attr_set_qos_class_np(&attr, qos, 0);
        result = pthread_create(handle, &attr, func, args);
        pthread_attr_destroy(&attr);
        return result;
    }
#else
    return pthread_create(handle, NULL, func, args);
#endif
#endif
}

int argon2_thread_join(argon2_thread_handle_t handle) {
#if defined(_WIN32)
    if (WaitForSingleObject((HANDLE)handle, INFINITE) == WAIT_OBJECT_0) {
        return CloseHandle((HANDLE)handle) != 0 ? 0 : -1;
    }
    return -1;
#else
    return pthread_join(handle, NULL);
#endif
}

void argon2_thread_exit(void) {
#if defined(_WIN32)
    _endthreadex(0);
#else
    pthread_exit(NULL);
#endif
}

#endif /* ARGON2_NO_THREADS */
