#lang racket/base
(require racket/cmdline
         racket/system
         racket/port
         racket/format
         racket/file
         racket/string
         (only-in "farm.rkt"
                  current-mode
                  farm-config?
                  farm-config-tag farm-config-options farm-config-content))

;; See "farm.rkt" for an overview.

;; ----------------------------------------

(define release? #f)
(define default-clean? #f)

(define-values (config-file config-mode
                            default-server default-pkgs 
                            default-dist-name default-dist-base default-dist-dir)
  (command-line
   #:once-each
   [("--release") "Create release-mode installers"
    (set! release? #t)]
   [("--clean") "Erase client directories before building"
    (set! default-clean? #t)]
   #:args (config-file config-mode 
                       server pkgs 
                       dist-name dist-base dist-dir)
   (values config-file config-mode 
           server pkgs 
           dist-name dist-base dist-dir)))

(define config (parameterize ([current-mode config-mode])
                 (dynamic-require (path->complete-path config-file) 'farm-config)))

(unless (farm-config? config)
  (error 'drive-clients 
         "configuration module did not provide a farm-configuration value: ~e"
         config))

;; ----------------------------------------

(define (merge-options opts c)
  (for/fold ([opts opts]) ([(k v) (in-hash (farm-config-options c))])
    (hash-set opts k v)))

(define (get-opt opts kw [default #f])
  (hash-ref opts kw default))

(define (get-content c)
  (farm-config-content c))

(define (client-name opts)
  (or (get-opt opts '#:name)
      (get-opt opts '#:host)
      "localhost"))

;; ----------------------------------------
;; Managing VirtualBox machines

(define VBoxManage (find-executable-path "VBoxManage"))
(define use-headless? #t)

(define (system*/show exe . args)
  (displayln (apply ~a #:separator " " 
                    (map (lambda (p) (if (path? p) (path->string p) p)) 
                         (cons exe args))))
  (apply system* exe args))

(define (system*/string . args)
  (define s (open-output-string))
  (parameterize ([current-output-port s])
    (apply system* args))
  (get-output-string s))

(define (vbox-state vbox)
  (define s (system*/string VBoxManage "showvminfo" vbox))
  (define m (regexp-match #rx"(?m:^State:[ ]*([a-z]+(?: [a-z]+)*))" s))
  (define state (and m (string->symbol (cadr m))))
  (case state
    [(|powered off| aborted) 'off]
    [(running saved paused) state]
    [(restoring) (vbox-state vbox)]
    [else 
     (eprintf "~a\n" s)
     (error 'vbox-state "could not get virtual machine status: ~s" vbox)]))

(define (vbox-control vbox what)
  (system* VBoxManage "controlvm" vbox what))

(define (vbox-start vbox)
  (apply system* VBoxManage "startvm" vbox 
         (if use-headless?
             '("--type" "headless")
             null))
  ;; wait for the machine to get going:
  (let loop ([n 0])
    (unless (eq? 'running (vbox-state vbox))
      (unless (= n 20)
        (sleep 0.5)
        (loop (add1 n))))))

(define call-with-vbox-lock
  (let ([s (make-semaphore 1)]
        [lock-cust (current-custodian)])
    (lambda (thunk)
      (define t (current-thread))
      (define ready (make-semaphore))
      (define done (make-semaphore))
      (parameterize ([current-custodian lock-cust])
        (thread (lambda () 
                  (semaphore-wait s)
                  (semaphore-post ready)
                  (sync t done)
                  (semaphore-post s))))
      (sync ready)
      (thunk)
      (semaphore-post done))))

(define (start-client c max-vm)
  (define vbox (get-opt c '#:vbox))
  (define (check-count)
    (define s (system*/string VBoxManage "list" "runningvms"))
    (unless ((length (string-split s "\n")) . < . max-vm)
      (error 'start-client "too many virtual machines running (>= ~a) to start: ~s"
             max-vm
             (client-name c))))
  (when vbox
    (printf "Starting VirtualBox machine ~s\n" vbox)
    (case (vbox-state vbox)
      [(running) (void)]
      [(paused) (vbox-control vbox "resume")]
      [(off saved) (call-with-vbox-lock
                    (lambda ()
                      (check-count)
                      (vbox-start vbox)))])
    (unless (eq? (vbox-state vbox) 'running)
      (error 'start-client "could not get virtual machine started: ~s" (client-name c))))
  ;; pause a little to let the VM get networkign ready, etc.
  (sleep 3))

(define (stop-client c)
  (define vbox (get-opt c '#:vbox))
  (when vbox
    (printf "Stopping VirtualBox machine ~s\n" vbox)
    (vbox-control vbox "savestate")
    (unless (eq? (vbox-state vbox) 'saved)
      (error 'start-client "virtual machine isn't in the expected saved state: ~s" c))))

;; ----------------------------------------

(define scp (find-executable-path "scp"))
(define ssh (find-executable-path "ssh"))

(define (ssh-script host port user . cmds)
  (for/and ([cmd (in-list cmds)])
    (or (not cmd)
        (apply system*/show ssh 
               "-p" (~a port)
               (if user 
                   (~a user "@" host)
                   host)
               cmd))))

(define (q s)
  (~a "\"" s "\""))

(define (client-args desc server pkgs dist-name dist-base dist-dir dist-suffix)
  (~a " SERVER=" server
      " PKGS=" (q pkgs)
      " DIST_DESC=" (q desc)
      " DIST_NAME=" (q dist-name)
      " DIST_BASE=" dist-base
      " DIST_DIR=" dist-dir
      " DIST_SUFFIX=" (q dist-suffix)
      " RELEASE_MODE=" (if release? "--release" (q ""))))

(define (unix-build c host port user server repo clean?
                    pkgs dist-name dist-base dist-dir dist-suffix)
  (define dir (or (get-opt c '#:dir)
                  "build/plt"))
  (define (sh . args) 
    (list "/bin/sh" "-c" (~a "'" (apply ~a args) "'")))
  (define j (or (get-opt c '#:j) 1))
  (ssh-script
   host port user
   (and clean?
        (sh "rm -rf  " (q dir)))
   (sh "if [ ! -d " (q dir) " ] ; then"
       " git clone " (q repo) " " (q dir) " ; "
       "fi")
   (sh "cd " (q dir) " ; "
       "git pull")
   (sh "cd " (q dir) " ; "
       "make -j " j " client"
       (client-args (client-name c)
                    server pkgs 
                    dist-name dist-base dist-dir dist-suffix)
       " CORE_CONFIGURE_ARGS=" (q (apply ~a #:separator " "
                                         (get-opt c '#:configure null))))))

(define (windows-build c host port user server repo clean?
                       pkgs dist-name dist-base dist-dir dist-suffix)
  (define dir (or (get-opt c '#:dir)
                  "build\\plt"))
  (define bits (or (get-opt c '#:bits) 64))
  (define vc (or (get-opt c '#:vc)
                 (if (= bits 32)
                     "x86"
                     "x64")))
  (define (cmd . args) 
    (list "cmd" "/c" (apply ~a args)))
  (ssh-script
   host port user
   (and clean?
        (cmd "IF EXIST " (q dir) " rmdir /S /Q " (q dir)))
   (cmd "IF NOT EXIST " (q dir) " git clone " (q repo) " " (q dir))
   (cmd "cd " (q dir)
        " && git pull")
   (cmd "cd " (q dir)
        " && \"c:\\Program Files" (if (= bits 64) " (x86)" "") "\\Microsoft Visual Studio 9.0\\vc\\vcvarsall.bat\""
        " " vc
        " && nmake win32-client" 
        (client-args (client-name c)
                     server pkgs 
                     dist-name dist-base dist-dir dist-suffix))))

(define (client-build c)
  (define host (or (get-opt c '#:host)
                   "localhost"))
  (define port (or (get-opt c '#:port)
                   22))
  (define user (get-opt c '#:user))
  (define server (or (get-opt c '#:server)
                     default-server))
  (define pkgs (or (get-opt c '#:pkgs)
                   default-pkgs))
  (define dist-name (or (get-opt c '#:dist-name)
                        default-dist-name))
  (define dist-base (or (get-opt c '#:dist-base)
                        default-dist-base))
  (define dist-dir (or (get-opt c '#:dist-dir)
                       default-dist-dir))
  (define dist-suffix (get-opt c '#:dist-suffix ""))
  (define repo (or (get-opt c '#:repo)
                   (~a "http://" server ":9440/.git")))
  (define clean? (let ([v (get-opt c '#:clean? 'none)])
                   (if (eq? v 'none)
                       default-clean?
                       v)))
  ((case (or (get-opt c '#:platform) 'unix)
     [(unix) unix-build]
     [else windows-build])
   c host port user server repo clean?
   pkgs dist-name dist-base dist-dir dist-suffix))

;; ----------------------------------------

(define (limit-and-report-failure c timeout-factor thunk)
  (define cust (make-custodian))
  (define timeout (or (get-opt c '#:timeout)
                      (* 30 60)))
  (define orig-thread (current-thread))
  (parameterize ([current-custodian cust])
    (thread (lambda ()
              (sleep (* timeout-factor timeout))
              ;; try nice interrupt, first:
              (break-thread orig-thread)
              (sleep 1)
              ;; force quit:
              (custodian-shutdown-all cust)))
    (with-handlers ([exn? (lambda (exn)
                            (log-error "~a failed..." (client-name c))
                            (log-error (exn-message exn)))])
      (thunk)))
  (custodian-shutdown-all cust))

(define (client-thread c sequential? thunk)
  (define log-dir (build-path "build" "drive"))
  (define log-file (build-path log-dir (client-name c)))
  (make-directory* log-dir)
  (printf "Logging build: ~a\n" log-file)
  (define (go)
    (define p (open-output-file log-file
                                #:exists 'truncate/replace))
    (file-stream-buffer-mode p 'line)
    (parameterize ([current-output-port p]
                   [current-error-port p])
      (thunk)))
  (cond
   [sequential? (go) (thread void)]
   [else (thread go)]))

;; ----------------------------------------

(void
 (let loop ([config config]
            [mode 'sequential]
            [opts (hasheq)])
   (case (farm-config-tag config)
     [(parallel sequential)
      (define new-opts (merge-options opts config))
      (define ts
        (map (lambda (c) (loop c
                               (car config)
                               new-opts))
             (get-content config)))
      (define (wait)
        (for ([t (in-list ts)])
          (sync t)))
      (cond
       [(eq? mode 'sequential) (wait) (thread void)]
       [else (thread wait)])]
     [else 
      (define c (merge-options opts config))
      (client-thread
       c
       (eq? mode 'sequential)
       (lambda ()
         (limit-and-report-failure
          c 2
          (lambda ()
            ;; start client, if a VM:
            (start-client c (or (get-opt c '#:max-vm) 1))
            ;; catch failure in build step proper, so we
            ;; can more likely stop the client:
            (limit-and-report-failure
             c 1
             (lambda () (client-build c)))
            ;; stop client, if a VM:
            (stop-client c)))))])))