#lang racket/base
(require "../common/phase.rkt"
         "../namespace/namespace.rkt"
         "../namespace/module.rkt"
         "../compile/module-use.rkt"
         "../host/linklet.rkt"
         "../compile/serialize.rkt"
         "../compile/instance.rkt"
         "../compile/eager-instance.rkt"
         "../compile/compiled-in-memory.rkt"
         "top-level-instance.rkt")

;; Run a representation of top-level code as produced by `compile-top`;
;; see "compile.rkt" and "compile-top.rkt"

(provide eval-top)

(define (eval-top c ns [eval-compiled eval-top])
  (define ld (if (compiled-in-memory? c)
                 (compiled-in-memory-linklet-directory c)
                 c))
  (if (hash-ref (linklet-directory->hash ld) #".multi" #f)
      (eval-multiple-tops c ns eval-compiled)
      (eval-single-top c ns)))

(define (eval-multiple-tops c ns eval-compiled)
  (cond
   [(compiled-in-memory? c)
    (let loop ([cims (compiled-in-memory-pre-compiled-in-memorys c)])
      (cond
       [(null? cims) void]
       [(null? (cdr cims))
        ;; Tail call:
        (eval-compiled (car cims) ns)]
       [else
        (eval-compiled (car cims) ns)
        (loop (cdr cims))]))]
   [else
    (define ht (linklet-directory->hash c))
    (let loop ([keys (sort (hash-keys ht) bytes<?)])
      (cond
       [(null? keys) (void)]
       [(equal? (car keys) #".multi") (loop (cdr keys))]
       [(null? (cdr keys))
        ;; Tail call:
        (eval-compiled (hash-ref ht (car keys)) ns)]
       [else
        (eval-compiled (hash-ref ht (car keys)) ns)
        (loop (cdr keys))]))]))

(define (eval-single-top c ns)
  (define ld (if (compiled-in-memory? c)
                 (compiled-in-memory-linklet-directory c)
                 c))
  (define h (linklet-directory->hash ld))
  (define link-instance
    (if (compiled-in-memory? c)
        (link-instance-from-compiled-in-memory c)
        (instantiate-linklet (eval-linklet (hash-ref h #".link"))
                             (list deserialize-instance
                                   (make-eager-instance-instance
                                    #:namespace ns
                                    #:dest-phase (namespace-phase ns)
                                    #:self (namespace-mpi ns)
                                    #:bulk-binding-registry (namespace-bulk-binding-registry ns))))))

  (define orig-phase (instance-variable-value link-instance 'original-phase))
  (define max-phase (instance-variable-value link-instance 'max-phase))
  (define phase-shift (phase- (namespace-phase ns) orig-phase))

  ;; Call the last thunk in tail position:
  ((for/fold ([prev-thunk void]) ([phase (in-range max-phase (sub1 orig-phase) -1)])
     (prev-thunk) ;; call a not-last thunk before proceeding with the next phase
     
     (define imports
       (for/list ([mu (in-list
                       (hash-ref (instance-variable-value link-instance 'phase-to-link-modules)
                                 phase
                                 null))])
         (namespace-module-use->instance ns mu #:phase-shift (phase- (phase+ phase phase-shift)
                                                                     (module-use-phase mu)))))

     (define phase-ns (namespace->namespace-at-phase ns (phase+ phase phase-shift)))

     (define inst (make-instance-instance
                   #:namespace phase-ns
                   #:phase-shift phase-shift
                   #:self (namespace-mpi ns)
                   #:bulk-binding-registry (namespace-bulk-binding-registry ns)
                   #:set-transformer! (lambda (name val)
                                        (namespace-set-transformer! ns
                                                                    (phase+ (sub1 phase) phase-shift)
                                                                    name
                                                                    val))))

     (define linklet
       (eval-linklet (hash-ref h (encode-linklet-directory-key phase) #f)))
     
     (cond
      [linklet
       (define i
         (parameterize ([current-namespace (if (zero-phase? phase)
                                               (current-namespace)
                                               phase-ns)])
           (instantiate-linklet linklet
                                (list* top-level-instance
                                       link-instance
                                       inst
                                       imports)
                                ;; Instantiation merges with the namespace's current instance:
                                (namespace->instance ns (phase+ phase phase-shift)))))
       (cond
        [(eqv? phase orig-phase)
         (let ([body-thunk (instance-variable-value i 'body-thunk)])
           (if (zero-phase? phase)
               body-thunk
               (lambda () (parameterize ([current-namespace phase-ns])
                       (body-thunk)))))]
        [else void])]
      [else void]))))

(define (link-instance-from-compiled-in-memory cim)
  (define link-instance (make-instance 'link))
  (instance-set-variable-value! link-instance 'original-phase
                                (compiled-in-memory-phase cim))
  (instance-set-variable-value! link-instance 'max-phase
                                (compiled-in-memory-max-phase cim))
  (instance-set-variable-value! link-instance 'phase-to-link-modules
                                (compiled-in-memory-phase-to-link-module-uses cim))
  (instance-set-variable-value! link-instance 'mpi-vector
                                (compiled-in-memory-mpis cim))
  (instance-set-variable-value! link-instance 'syntax-literalss
                                (compiled-in-memory-syntax-literalss cim))
  link-instance)