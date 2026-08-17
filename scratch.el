
(defun glmakie-reload ()
  (let ((tmp (make-temp-file "glmakie_el_" nil ".so")))
    (copy-file "glmakie_el.so" tmp t)
    (module-load tmp)))

(progn
  (glmakie-reload)
  (glmakie-init "/dev/shm/glmakie_emacs.bin")

  )

;; The image specification object uniquely (with respect to ‘eq’) identifies a
;; canvas image object.
(setq glmakie-canvas
      `(image :type canvas
              :id glmakie2
              :data-width 712
              :data-height 423))

(progn
  (glmakie-update glmakie-canvas)
  (canvas-refresh glmakie-canvas)
  )

(insert "\n" (propertize "#" 'display glmakie-canvas))
#
