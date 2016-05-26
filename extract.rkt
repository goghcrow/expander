#lang racket/base
(require racket/cmdline
         "set.rkt"
         "phase.rkt"
         "cache-for-boot.rkt"
         "linklet.rkt"
         "serialize.rkt"
         "module-use.rkt"
         "binding.rkt"
         "runtime-primitives.rkt"
         (prefix-in new: "module-path.rkt"))

;; Collect all of the linklets need to run phase 0 of the specified
;; module while keeping the module's variables that are provided from
;; phase 0. In other words, keep enogh to produce any value or affect
;; that `dynamic-require` would produce.

(define start-mod-path "main.rkt")

(define cache-dir
  (command-line
   #:once-any
   [("-l") module-path "Extract starting with <module-path>"
    (set! start-mod-path (string->symbol module-path))]
   #:args
   (cache-dir)
   cache-dir))

;; All relevant files must have been built and cached via "boot.rkt"
(define cache (make-cache cache-dir))

;; We load each module's declation and phase-specific
;; linklets once
(struct compiled-module (declaration        ; linklet instance
                         phase-to-linklet)) ; phase -> linklet
(define compiled-modules (make-hash))

;; A "link" represent a linklet reference, which is a name
;; (corersponds to a `resolved-module-path-name` result) plus a phase
(struct link (name phase) #:prefab)

;; A linklet-info is a phase-specific slice of a module --- mainly a
;; linklet, but we group the linklet together with metadata from the
;; module's declaration linklet
(struct linklet-info (linklet          ; the implementation, or #f if the implementation is empty
                      imports          ; links for import "arguments"
                      re-exports       ; links for variables re-exported
                      variables        ; variables defined in the implementation; for detecting re-exports
                      side-effects?))  ; whether the implementaiton has side effects other than variable definition

;; All linklets that find we based on module `requires` from the
;; starting module
(define seen (make-hash)) ; link -> linklet-info

;; The subset of `seen` that have that non-empty linklets
(define linklets (make-hash)) ; link -> linklet-info
;; The same linklets are referenced this list, but kept in reverse
;; order of instantiation:
(define linklets-in-order null)

;; Which linklets (as represented by a "link") are actually needed to run
;; the code, which includes anything referenced by the starting
;; point's exports and any imported linklet that has a side effect:
(define needed (make-hash)) ; link -> value for reason

;; Use the host Racket's module name resolver to normalize the
;; starting module path:
(define start-name
  (resolved-module-path-name
   (module-path-index-resolve
    (module-path-index-join start-mod-path #f))))

;; We always start at phase 0
(define start-link (link start-name 0))

;; Convert a module path index implemented by our compiler to
;; a module path index in the host Racket:
(define (build-native-module-path-index mpi wrt-name)
  (define-values (mod-path base) (new:module-path-index-split mpi))
  (cond
   [(not mod-path) (make-resolved-module-path wrt-name)]
   [else
    (module-path-index-join mod-path
                            (and base
                                 (build-native-module-path-index base wrt-name)))]))

;; Convert one of our module path indexes and a name to
;; the referenced name
(define (module-path-index->module-name mod name)
  (define p (build-native-module-path-index mod name))
  (resolved-module-path-name
   (if (resolved-module-path? p)
       p
       (module-path-index-resolve p))))

;; Get (possibly already-loaded) representation of a compiled module
;; from the cache
(define (get-compiled-module name root-name)
  (or (hash-ref compiled-modules name #f)
      (let ([local-name name])
                                        ;: Seeing this module for the first time
        (define cd (get-cached-compiled cache root-name void))
        (unless cd
          (error "unavailable in cache:" name))
        ;; For submodules, recur into the compilation directory:
        (define h (let loop ([cd cd] [name name])
                    (define h (linklet-directory->hash cd))
                    (if (or (not (pair? name))
                            (null? (cdr name)))
                        h
                        (loop (hash-ref h (encode-linklet-directory-key (cadr name)))
                              (cdr name)))))
        ;; Instantiate the declaration linklet
        (define decl (instantiate-linklet (eval-linklet (hash-ref h #""))
                                                   (list deserialize-instance)))
        ;; Make a `compiled-module` structure to represent the compilaed module
        ;; and all its linklets (but not its submodules, although they're in `h`)
        (define comp-mod (compiled-module decl h))
        (hash-set! compiled-modules name comp-mod)
        comp-mod)))

(define (get-linklets! lnk)
  (define name (link-name lnk))
  (define phase (link-phase lnk))
  (define root-name (if (pair? name) (car name) name)) ; strip away submodule path
  (unless (or (symbol? root-name) ; skip pre-defined modules
              (hash-ref seen lnk #f))
    ;; Seeing this module+phase combination for the first time
    (log-error "Getting ~s at ~s" name phase)
    (define comp-mod (get-compiled-module name root-name))

    ;; Extract the relevant linklet (i.e., at a given phase)
    ;; from the compiled module
    (define linklet
      (hash-ref (compiled-module-phase-to-linklet comp-mod)
                (encode-linklet-directory-key phase)
                #f))

    ;; Extract other metadata at the module level:
    (define reqs (instance-variable-value (compiled-module-declaration comp-mod) 'requires))
    (define provs (instance-variable-value (compiled-module-declaration comp-mod) 'provides))

    ;; Extract phase-specific (i.e., compiliation-unit-specific) info on variables:
    (define vars (if linklet
                     (list->set (compiled-linklet-variables linklet))
                     null))
    ;; Extract phase-specific (i.e., compiliation-unit-specific) info on side effects:
    (define side-effects? (and
                           (member phase (instance-variable-value (compiled-module-declaration comp-mod)
                                                                  'side-effects))
                           #t))
    ;; Extract phase-specific mapping of the linklet arguments to modules
    (define uses
      (hash-ref (instance-variable-value (compiled-module-declaration comp-mod) 'phase-to-link-modules)
                phase
                null))
   
    (define dependencies
      (for*/list ([(req-phase reqs) (in-hash reqs)]
                  [req (in-list reqs)])
        ;; we want whatever required module will have at this module's `phase`
        (define at-phase (phase- phase req-phase))
        (link (module-path-index->module-name req name)
              at-phase)))

    ;; Get linklets implied by the module's `require` (although some
    ;; of those may turn out to be dead code)
    (for ([dependency (in-list dependencies)])
      (get-linklets! dependency))
    
    ;; Imports are the subset of the transitive closure of `require`
    ;; that are used by this linklet's implementation
    (define imports
      (for/list ([mu (in-list uses)])
        (link (module-path-index->module-name (module-use-module mu) name)
              (module-use-phase mu))))
    (when (and (pair? imports)
               (not linklet))
      (error "no implementation, but uses arguments?" name phase))

    ;; Re-exports are the subset of the transitive closure of
    ;; `require` that have variables that are re-exported from this
    ;; linklet; relevant only for the starting point
    (define re-exports
      (and (equal? lnk start-link)
           (set->list
            (for*/set ([(sym binding) (in-hash (hash-ref provs phase #hasheq()))]
                       [l (in-value
                           (link (module-path-index->module-name (module-binding-module binding) name)
                                 (module-binding-phase binding)))]
                       [re-li (in-value (hash-ref linklets l #f))]
                       #:when (and re-li
                                   (set-member? (linklet-info-variables re-li) (module-binding-sym binding))))
              l))))

    (define li (linklet-info linklet imports re-exports vars side-effects?))

    (hash-set! seen lnk li)
    
    (when linklet
      (hash-set! linklets lnk li)
      (set! linklets-in-order (cons lnk linklets-in-order)))))

;; Compute which linklets are actually used as imports
(define (needed! lnk reason)
  (unless (hash-ref needed lnk #f)
    (define li (hash-ref seen lnk #f))
    (when li
      (hash-set! needed lnk reason)
      (for ([in-lnk (in-list (linklet-info-imports li))])
        (needed! in-lnk lnk)))))

;; ----------------------------------------
;; Gather needed links

;; Start with the given link, and follow dependencies
(get-linklets! start-link)
(needed! start-link 'start)

;; We also want the starting name's re-exports:
(for ([ex-lnk (in-list (linklet-info-re-exports (hash-ref seen start-link)))])
  (needed! ex-lnk `(re-export ,start-link)))

;; Anything that shows up in `codes` with a side effect also counts
(for ([(lnk li) (in-hash linklets)])
  (when (linklet-info-side-effects? li)
    (needed! lnk 'side-effect)))

;; ----------------------------------------
;; Report the results

(log-error "Traversed ~s modules" (hash-count compiled-modules))
(log-error "Got ~s relevant linklets" (hash-count linklets))
(log-error "Need ~s of those linklets" (hash-count needed))

;; Check whether any nneded linklet needs a an instance of a
;; pre-defined instance that is not part of the runtime system:
(define complained? #f)
(for ([lnk (in-list linklets-in-order)])
  (define needed-reason (hash-ref needed lnk #f))
  (when needed-reason
    (define li (hash-ref linklets lnk))
    (for ([in-lnk (in-list (linklet-info-imports li))])
      (define p (link-name in-lnk))
      (when (and (symbol? p)
                 (not (member p runtime-instances))
                 (hash-ref needed in-lnk #t))
        (unless complained?
          (log-error "~a\n~a"
                     "Unfortunately, some linklets depend on pre-defined host instances"
                     "that are not part of the runtime system:")
          (set! complained? #t))
        (log-error " - ~a at ~s\n   needs ~s\n   needed by ~s"
                   (link-name lnk)
                   (link-phase lnk)
                   p
                   needed-reason)))))

(when complained?
  (exit 1))