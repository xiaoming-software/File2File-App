// Run WebrpcClient_SendFile on a detached pthread so the Flutter UI isolate
// stays responsive (matches File2File-Desktop background-thread SendFile).
// Progress continues via type=3/4 and NAS backPut on the callback socket.

#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

typedef uintptr_t GoUintptr;

extern int WebrpcClient_SendFile(GoUintptr handle, unsigned int sessionId,
                                 char* filePath);

typedef void (*WebrpcSendFileDoneFn)(int32_t result);

typedef struct {
  GoUintptr handle;
  unsigned int session_id;
  char* path;
  WebrpcSendFileDoneFn done;
} WebrpcSendFileJob;

static void* webrpc_sendfile_thread(void* arg) {
  WebrpcSendFileJob* job = (WebrpcSendFileJob*)arg;
  int ret = 0;
  if (job != NULL && job->path != NULL) {
    ret = WebrpcClient_SendFile(job->handle, job->session_id, job->path);
  }
  WebrpcSendFileDoneFn done = job != NULL ? job->done : NULL;
  if (job != NULL) {
    free(job->path);
    free(job);
  }
  if (done != NULL) {
    done((int32_t)ret);
  }
  return NULL;
}

// Returns 1 if the worker thread was started; 0 on immediate failure.
// [done] is invoked from the worker thread (Dart NativeCallable.listener OK).
__attribute__((visibility("default"), used)) int WebrpcClient_SendFileAsync(
    GoUintptr handle, unsigned int sessionId, const char* filePath,
    WebrpcSendFileDoneFn done) {
  if (handle == 0 || sessionId == 0 || filePath == NULL || done == NULL) {
    return 0;
  }
  WebrpcSendFileJob* job =
      (WebrpcSendFileJob*)calloc(1, sizeof(WebrpcSendFileJob));
  if (job == NULL) {
    return 0;
  }
  job->handle = handle;
  job->session_id = sessionId;
  job->path = strdup(filePath);
  job->done = done;
  if (job->path == NULL) {
    free(job);
    return 0;
  }

  pthread_attr_t attr;
  pthread_attr_init(&attr);
  pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
  pthread_t thread;
  const int rc = pthread_create(&thread, &attr, webrpc_sendfile_thread, job);
  pthread_attr_destroy(&attr);
  if (rc != 0) {
    free(job->path);
    free(job);
    return 0;
  }
  return 1;
}
