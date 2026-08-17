#include "emacs-module.h"
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

int plugin_is_GPL_compatible;

static uint32_t* shared_buffer = MAP_FAILED;
#define BUFFER_COUNT 712*423
#define BUFFER_SIZE 4 * BUFFER_COUNT

char* alloc_emacs_string(emacs_env* env, emacs_value emacs_str) {
  ptrdiff_t str_len;
  env->copy_string_contents(env, emacs_str, NULL, &str_len);

  char* str = (char*)malloc(str_len);
  env->copy_string_contents(env, emacs_str, str, &str_len);
  return str;
}

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

/*
 * Lisp signature: (glmakie-init "/dev/shm/glmakie_emacs.bin")
 */
static emacs_value Finit(emacs_env* env, ptrdiff_t nargs, emacs_value args[],
                         void* data) {
  message(env, "Initing...");

  if (shared_buffer != MAP_FAILED) {
    message(env, "Unmapping buffer...");
    if (!munmap(shared_buffer, BUFFER_SIZE)) {
      message(env, "Error unmapping buffer.");
    }
  }

  char path[256];
  ptrdiff_t path_len = sizeof(path);
  env->copy_string_contents(env, args[0], path, &path_len);

  // Open and map the file
  int fd = open(path, O_RDONLY);
  if (fd < 0) {
    message(env, "Failed to open file");
    return env->intern(env, "nil");
  }

  shared_buffer = mmap(NULL, BUFFER_SIZE, PROT_READ, MAP_SHARED, fd, 0);
  close(fd); // Safe to close fd after mmap

  if (shared_buffer == MAP_FAILED) {
    message(env, "MMap failed");
    return env->intern(env, "nil");
  }

  return env->intern(env, "t");
}

/*
 * Lisp signature: (glmakie-read MY-VECTOR)
 */
static emacs_value Fread(emacs_env* env, ptrdiff_t nargs, emacs_value args[],
                         void* data) {
  if (shared_buffer == MAP_FAILED) {
    message(env, "Buffer unintialized");
    return env->intern(env, "nil");
  }

  emacs_value vec = args[0];
  ptrdiff_t vec_len = env->vec_size(env, vec);

  // Only write up to the vector's capacity or the mmap size
  ptrdiff_t limit = (vec_len < BUFFER_COUNT) ? vec_len : BUFFER_COUNT;

  for (ptrdiff_t i = 0; i < limit; i++) {
    emacs_value val = env->make_integer(env, shared_buffer[i]);
    env->vec_set(env, vec, i, val);
  }

  return env->intern(env, "t");
}

/* Lisp: (glmakie-update CANVAS) */
static emacs_value Fupdate(emacs_env *env, ptrdiff_t nargs, emacs_value args[], void *data) {
  if (shared_buffer == MAP_FAILED) {
    message(env, "Buffer unintialized");
    return env->intern(env, "nil");
  }

  uint32_t *canvas_buffer = env->canvas_data(env, args[0]);

  if (canvas_buffer) {
    memcpy(canvas_buffer, shared_buffer, BUFFER_SIZE);
  }
  return env->intern(env, "t");
}

int emacs_module_init(struct emacs_runtime* rt) {
  emacs_env* env = rt->get_environment(rt);

  emacs_value init_fun =
      env->make_function(env, 1, 1, Finit, "Map the shared memory file.", NULL);
  bind_function(env, "glmakie-init", init_fun);
  
  emacs_value read_fun =
      env->make_function(env, 1, 1, Fread, "Read data and place in vector.", NULL);
  bind_function(env, "glmakie-read", read_fun);
  
  emacs_value update_fun =
      env->make_function(env, 1, 1, Fupdate, "Update CANVAS", NULL);
  bind_function(env, "glmakie-update", update_fun);

  return 0;
}
