
(defun glmakie-reload ()
  (let ((tmp (make-temp-file "glmakie_el_" nil ".so")))
    (copy-file "glmakie_el.so" tmp t)
    (module-load tmp)))

(glmakie-reload)


(glmakie-init "/dev/shm/glmakie_emacs.bin")

(setq glmakie-buffer (make-vector (* 3 2) 0.0))

(glmakie-read glmakie-buffer)
glmakie-buffer

(append glmakie-buffer nil)
(aref glmakie-buffer 1)


(setq glmakie-canvas
      `(image :type canvas
              :id glmakie
              :data-width 3
              :data-height 2))

(insert (propertize "#" 'display glmakie-canvas))
