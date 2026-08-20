#include "emacs-module.h"
#include <fcntl.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

int plugin_is_GPL_compatible;

/// Emacs utils

/*
 * Display a message in the message buffer.
 */
static void message(emacs_env* env, const char* msg) {
  char logmsg[265];
  snprintf(logmsg, sizeof(logmsg), "GLMakie(C): %s", msg);
  emacs_value Qmessage = env->intern(env, "message");
  emacs_value Qstr = env->make_string(env, logmsg, strlen(logmsg));
  env->funcall(env, Qmessage, 1, (emacs_value[]){Qstr});
}

/*
 * Bind a function to an emacs symbol.
 */
static void bind_function(emacs_env* env, const char* name, emacs_value Sfun) {
  emacs_value Qsym = env->intern(env, name);
  emacs_value Qfset = env->intern(env, "fset");
  emacs_value fset_args[] = {Qsym, Sfun};
  env->funcall(env, Qfset, 2, fset_args);
}

/// Canvas buffer

/*
 * Holds pointer and size to mmaped color buffer of a GLMakie plot.
 *  
 * This struct is stored on the heap, and a pointer to it is passed to Emacs in
 * a special "user_ptr" object. This object contains a finalizer that is called
 * when the elisp object is garbage collected. See 'finalize_canvas_buffer'.
 */
typedef struct {
  uint32_t* data;
  size_t size;
  char* filepath;
} CanvasBuffer;

/*
 * Unmaps the mmaped buffer and deallocates the filepath field.
 */
static void free_canvas_buffer(CanvasBuffer* buf) {
  if (buf->data == NULL || buf->size == 0)
    return;
  munmap(buf->data, buf->size);
  if (buf->filepath != NULL)
    free(buf->filepath);
  free(buf);
}

/*
 * Finalizer passed to emacs CanvasBuffer ptr object that gets called when it
 * gets garbage collected.
  */
static void finalize_canvas_buffer(void* buf_ptr) {
  if (buf_ptr == NULL)
    return;
  CanvasBuffer* buf = (CanvasBuffer*)buf_ptr;
  free_canvas_buffer(buf);
}

/*
 * Mmap the file path with the given size, returns its pointer on success or
 * NULL on failure.
 */
static uint32_t* mmap_buf(emacs_env* env, char* path, size_t size) {
  // Open and map the file
  int fd = open(path, O_RDONLY);
  if (fd < 0) {
    message(env, "Failed to open file");
    return NULL;
  }

  // Mmap. We can safely close the fd afterwards
  uint32_t* buf_data = mmap(NULL, size, PROT_READ, MAP_SHARED, fd, 0);
  close(fd);

  if (buf_data == MAP_FAILED) {
    message(env, "MMap failed");
    return NULL;
  }

  return buf_data;
}

/// Emacs functions

/*
 * Lisp: (glmakie--init SHM-PATH SIZE)
 * Mmap and return elisp pointer structure to CanvasBuffer struct.
 */
static emacs_value Finit(emacs_env* env, ptrdiff_t nargs, emacs_value args[],
                         void* data) {
  char path[256];
  ptrdiff_t path_len = sizeof(path);
  if (!env->copy_string_contents(env, args[0], path, &path_len)) {
    message(env, "Error copying path contents");
    return env->intern(env, "nil");
  }

  size_t size = env->extract_integer(env, args[1]) * 4;

  uint32_t* buf_data = mmap_buf(env, path, size);
  if (buf_data == NULL)
    return env->intern(env, "nil");

  // Store buf ptr in struct with size so we can unmap it later
  CanvasBuffer* buf = malloc(sizeof(CanvasBuffer));
  buf->data = buf_data;
  buf->size = size;
  buf->filepath = malloc(path_len);
  strcpy(buf->filepath, path);

  // Make emacs hold it for me :) W emacs
  return env->make_user_ptr(env, finalize_canvas_buffer, buf);
}

/*
 * Lisp: (glmakie--resize BUF-PTR SIZE)
 * Remap the shared buffer to a different size.
 */
static emacs_value Fresize(emacs_env* env, ptrdiff_t nargs, emacs_value args[],
                           void* data) {
  CanvasBuffer* data_buf = (CanvasBuffer*)env->get_user_ptr(env, args[0]);
  if (data_buf == NULL) {
    message(env, "Buffer pointer is NULL");
    return env->intern(env, "nil");
  }

  //  First munmap
  if (data_buf->data != NULL && data_buf->size > 0) {
    if (munmap(data_buf->data, data_buf->size) != 0) {
      message(env, "Munmap failed");
      return env->intern(env, "nil");
    }
    data_buf->data = NULL;
    data_buf->size = 0;
  }

  // Mmap again
  size_t new_size = env->extract_integer(env, args[1]) * 4;
  data_buf->data = mmap_buf(env, data_buf->filepath, new_size);
  if (data_buf->data == NULL) {
    message(env, "Freeing buffer data");
    free_canvas_buffer(data_buf);
    return env->intern(env, "nil");
  }
  data_buf->size = new_size;

  return env->intern(env, "t");
}

/*
 * Lisp: (glmakie--read BUF-PTR CANVAS)
 * Updates the canvas with the shared buffer data.
 */
static emacs_value Fread(emacs_env* env, ptrdiff_t nargs, emacs_value args[],
                         void* data) {
  CanvasBuffer* data_buf = (CanvasBuffer*)env->get_user_ptr(env, args[0]);
  if (data_buf == NULL) {
    message(env, "Buffer pointer is NULL");
    return env->intern(env, "nil");
  }
  if (data_buf->data == NULL) {
    message(env, "Buffer is NULL");
    return env->intern(env, "nil");
  }

  emacs_value canvas = args[1];
  uint32_t* canvas_buf =
      env->is_not_nil(env, canvas) ? env->canvas_data(env, canvas) : 0;

  if (canvas_buf) {
    memcpy(canvas_buf, data_buf->data, data_buf->size);
  }
  return env->intern(env, "t");
}

/// Module init

int emacs_module_init(struct emacs_runtime* rt) {
  emacs_env* env = rt->get_environment(rt);

  emacs_value init_fun = env->make_function(
      env, 2, 2, Finit,
      "Mmap the canvas shared memory file and return its pointer", NULL);
  bind_function(env, "glmakie--init", init_fun);

  emacs_value resize_fun =
      env->make_function(env, 2, 2, Fresize, "Resize the mmaped region", NULL);
  bind_function(env, "glmakie--resize", resize_fun);

  emacs_value read_fun = env->make_function(
      env, 2, 2, Fread,
      "Update CANVAS by reading from the shared memory buffer", NULL);
  bind_function(env, "glmakie--read", read_fun);

  return 0;
}
