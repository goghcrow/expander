#lang racket/base
(require "serialize-property.rkt"
         "syntax.rkt"
         "scope.rkt" ; defines `prop:bulk-binding`
         "binding.rkt"
         "module-path.rkt")

(provide provide-binding-to-require-binding

         make-bulk-binding-registry
         register-bulk-provide!
         current-bulk-binding-fallback-registry

         bulk-binding
         
         deserialize-bulk-binding)

;; When a require is something like `(require racket/base)`, then
;; we'd like to import the many bindings from `racket/base` in one
;; fast step, and we'd like to share the information in syntax objects
;; from many different modules that all import `racket/base`. A
;; "bulk binding" implements that fast binding and sharing.

;; The difficult part is restoring sharing when a syntax object is
;; unmarshaled, and also leaving the binding information in the
;; providing moduling instead of the requiring module. Keeping the
;; information with the providing module should be ok, because
;; resolving a chain of module mports should ensure that the relevant
;; module is loaded before a syntax object with a bulk binding is used.
;; Still, we have to communicate information from the loading process
;; down the binding-resolving process.

;; A bulk-binding registry manages that connection. The registry is
;; similar to the module registry, in that it maps a resolved module
;; name to provide information. But it has only the provide
;; information, and not the rest of the module's implementation.

;; ----------------------------------------

;; Helper for both regular imports and bulk bindings, which converts a
;; providing module's view of a binding to a requiring mdoule's view.
(define (provide-binding-to-require-binding out-binding ; the provided binding
                                            sym         ; the symbolic name of the provide
                                            #:self self ; the providing module's view of itself
                                            #:mpi mpi   ; the requiring module's view
                                            #:provide-phase-level provide-phase-level
                                            #:phase-shift phase-shift)
  (define from-mod (module-binding-module out-binding))
  (struct-copy module-binding out-binding
               [module (module-path-index-shift from-mod self mpi)]
               [nominal-module mpi]
               [nominal-phase provide-phase-level]
               [nominal-sym sym]
               [nominal-require-phase phase-shift]
               [frame-id #:parent binding #f]))


;; ----------------------------------------

(struct bulk-binding ([provides #:mutable] ; mutable so table can be found lazily on unmarshal
                      [self #:mutable]     ; the providing module's self
                      mpi                  ; this binding's view of the providing module
                      provide-phase-level  ; providing module's import phase
                      phase-shift)         ; providing module's instantiation phase
        #:property prop:bulk-binding
        (bulk-binding-class
         (lambda (b reg mpi-shifts)
           (or (bulk-binding-provides b)
               ;; Here's where we find provided bindings for unmarshaled syntax
               (let ([mod-name (module-path-index-resolve
                               (apply-syntax-shifts
                                (bulk-binding-mpi b)
                                mpi-shifts))])
                 (unless reg
                   (error "namespace mismatch: no bulk-binding registry available:"
                          mod-name))
                 (define table (bulk-binding-registry-table reg))
                 (define bulk-provide (hash-ref table mod-name #f))
                 (unless bulk-provide
                   (error "namespace mismatch: bulk bindings not found in registry for module:"
                          mod-name))
                 ;; Reset `provide` and `self` to the discovered information
                 (set-bulk-binding-self! b (bulk-provide-self bulk-provide))
                 (define provides (hash-ref (bulk-provide-provides bulk-provide)
                                            (bulk-binding-provide-phase-level b)))
                 (set-bulk-binding-provides! b provides)
                 provides)))
         (lambda (b binding sym)
           ;; Convert the provided binding to a required binding on
           ;; demand during binding resolution
           (provide-binding-to-require-binding
            binding sym
            #:self (bulk-binding-self b)
            #:mpi (bulk-binding-mpi b)
            #:provide-phase-level (bulk-binding-provide-phase-level b)
            #:phase-shift (bulk-binding-phase-shift b))))
        #:property prop:serialize
        ;; Serialization drops the `provides` table and the providing module's `self`
        (lambda (b ser)
          `(deserialize-bulk-binding
            ,(ser (bulk-binding-mpi b))
            ,(ser (bulk-binding-provide-phase-level b))
            ,(ser (bulk-binding-phase-shift b)))))

(define (deserialize-bulk-binding mpi provide-phase-level phase-shift)
  (bulk-binding #f #f mpi provide-phase-level phase-shift))

;; Although a bulk binding registry is associated to a syntax object
;; when a module is run, it's possible for a scope that contains a
;; bulk binding to get added to another syntax object that doesn't
;; have the binding. So, have the expander set a fallback.
(define current-bulk-binding-fallback-registry
  (make-parameter #f))

;; ----------------------------------------

;; A blk binding registry has just the provde part of a module, for
;; use in resolving bulk bindings on unmarshal
(struct bulk-provide (self provides))

;; A bulk-binding-registry object is attached to every syntax object
;; in an instantiated module, so that binding resolution on the
;; module's syntax literals can find tables of provided variables
;; based on module names
(struct bulk-binding-registry (table)) ; resolve-module-name -> bulk-provide

(define (make-bulk-binding-registry)
  (bulk-binding-registry (make-hasheq)))

;; Called when a module is instantiated to register iits provides:
(define (register-bulk-provide! bulk-binding-registry mod-name self provides)
  (hash-set! (bulk-binding-registry-table bulk-binding-registry)
             mod-name
             (bulk-provide self provides)))