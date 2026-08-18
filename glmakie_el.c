#include "emacs-module.h"
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdbool.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

int plugin_is_GPL_compatible;

static uint32_t* shared_buffer = MAP_FAILED;
static size_t buffer_size = 0;


/// Emacs utils

static void message(emacs_env* env, const char* msg) {
  emacs_value Qmessage = env->intern(env, "message");
  emacs_value Qstr = env->make_string(env, msg, strlen(msg));
  env->funcall(env, Qmessage, 1, (emacs_value[]){Qstr});
}

static void bind_function(emacs_env* env, const char* name, emacs_value Sfun) {
  emacs_value Qsym = env->intern(env, name);
  emacs_value Qfset = env->intern(env, "fset");
  emacs_value fset_args[] = {Qsym, Sfun};
  env->funcall(env, Qfset, 2, fset_args);
}

/// Core functions

static int mmap_buffer(const char* path, size_t size) {
  // Unmap if already mapped
  if (shared_buffer != MAP_FAILED) {
    if (munmap(shared_buffer, buffer_size) != 0)
      return 1;
    buffer_size = 0;
  }
  
  // Open and map the file
  int fd = open(path, O_RDONLY);
  if (fd < 0) return 2;

  shared_buffer = mmap(NULL, size, PROT_READ, MAP_SHARED, fd, 0);
  close(fd); // Safe to close fd after mmap

  if (shared_buffer == MAP_FAILED)
    return 3;

  buffer_size = size;
  return 0;
}

/// Emacs functions

/*
 * Lisp: (glmakie--mmap SHM-PATH SIZE)
 */
static emacs_value Fmmap(emacs_env* env, ptrdiff_t nargs, emacs_value args[],
                         void* data) {
  char path[256];
  ptrdiff_t path_len = sizeof(path);
  env->copy_string_contents(env, args[0], path, &path_len);
  
  size_t size = env->extract_integer(env, args[1]) * 4;

  int result = mmap_buffer(path, size);
  if (result == 0)
    return env->intern(env, "t");
  if (result == 1) {
    message(env, "Error unmapping buffer.");
  } else if (result == 2) {
    message(env, "Failed to open file");
  } else if (result == 3) {
    message(env, "MMap failed");
  }
  return env->intern(env, "nil");
}

/*
 * Lisp: (glmakie--update CANVAS)
 * Updates the canvas with the shared buffer data.
 */
static emacs_value Fupdate(emacs_env *env, ptrdiff_t nargs, emacs_value args[], void *data) {
  if (shared_buffer == MAP_FAILED) {
    message(env, "Buffer unintialized");
    return env->intern(env, "nil");
  }

  emacs_value canvas = args[0];
  uint32_t* canvas_buffer = env->is_not_nil(env, canvas) ? env->canvas_data(env, canvas) : 0;

  if (canvas_buffer) {
    memcpy(canvas_buffer, shared_buffer, buffer_size);
  }
  return env->intern(env, "t");
}

int emacs_module_init(struct emacs_runtime* rt) {
  emacs_env* env = rt->get_environment(rt);

  emacs_value mmap_fun =
      env->make_function(env, 2, 2, Fmmap, "Mmap the canvas shared memory file", NULL);
  bind_function(env, "glmakie--mmap", mmap_fun);
  
  emacs_value update_fun =
      env->make_function(env, 1, 1, Fupdate, "Update CANVAS", NULL);
  bind_function(env, "glmakie--update", update_fun);

  return 0;
}
