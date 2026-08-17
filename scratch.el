
;;; Server

(defvar glmakie--process nil)
(defvar glmakie--process-buf-name "*glmakie process*")

(defun glmakie-connect ()
  (let ((process-buf (get-buffer-create glmakie--process-buf-name)))
    (setq glmakie--process
          (open-network-stream
           "glmakie-process"
           process-buf
           "localhost"
           8888))
    (set-process-filter glmakie--process #'glmakie--server-process-filter)
    ))

(defun glmakie--server-process-filter (proc str)
  (when (buffer-live-p (process-buffer proc))
    (with-current-buffer (process-buffer proc)
      (goto-char (point-max))
      (insert str)
      (set-marker (process-mark proc) (point))

      (message "Got: %s" str))))

(defun glmakie--send-resize (height width)
  (process-send-string
   glmakie--process
   (format "RESIZE %d %d\n" height width)))

(glmakie-connect)



;;; Module

(defun glmakie-reload ()
  (let ((tmp (make-temp-file "glmakie_el_" nil ".so")))
    (copy-file "glmakie_el.so" tmp t)
    (module-load tmp)))

(progn
  (glmakie-reload)
  (glmakie-init "/dev/shm/glmakie_emacs.bin")

  )

;;; Canvas

(glmakie--send-resize 100 300)
    
;; The image specification object uniquely (with respect to ‘eq’) identifies a
;; canvas image object.
(setq glmakie-canvas
      `(image :type canvas
              :id glmakie2
              :data-width 712
              :data-height 423))

(defun glmakie-resize (height width)
  (setf (plist-get (cdr glmakie-canvas) :data-height) height
        (plist-get (cdr glmakie-canvas) :data-width) width)
  (glmakie--send-resize height width))

(progn
  (glmakie-update glmakie-canvas)
  (canvas-refresh glmakie-canvas)
  )

(insert "\n" (propertize "#" 'display glmakie-canvas))
#
