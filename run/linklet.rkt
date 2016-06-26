#lang racket/base
(require racket/unsafe/undefined
         "../common/set.rkt"
         "../syntax/datum-map.rkt"
         "../host/correlate.rkt"
         "../common/reflect-hash.rkt"
         "../boot/runtime-primitive.rkt"
         "linklet-operation.rkt")

;; A "linklet" is the primitive form of separate (not necessarily
;; independent) compilation and linking. A `linklet` is serializable
;; linklet, and instantiation of a linklet produces an "instance"
;; given other instances to satisfy its imports. An instance, which
;; essentially just maps symbols to values, can also be created
;; directly, so it serves as the bridge between the worlds of values
;; and compiled objects.

;; A "linklet bundle" is similarly a primitive construct that is
;; essentially a mapping of symbols and fixnums to linklets, symbols,
;; and symbol lists. A bundle is used, for example, to implement a
;; module (which is a collection of linklets plus some static
;; metadata).

;; Finally, a "linklet directory" is a primitive construct that is a
;; mapping of #f to a bundle and symbols to linklet directories. The
;; intent is that individual linklet bundles can be efficiently
;; extracted from the marshaled form of a linklet directory --- the
;; primitive form of accessing an indvidual submodule.

;; For bootstrapping, we can implement linklets here by compiling
;; `linklet` to `lambda`. If the host Racket supports linklets, then
;; this is not necessary, except to the degree that `compile-linklet`
;; needs to be replaced with a variant that "compiles" to source.

;; See "linklet-operation.rkt":
(linklet-operations=> provide)

;; Helpers for "extract.rkt"
(provide linklet-compile-to-s-expr  ; a parameter; whether to "compile" to a source form
         linklet-as-s-expr?

         s-expr-linklet-importss+localss
         s-expr-linklet-exports+locals
         s-expr-linklet-body)

(struct linklet (compiled-proc  ; takes self instance plus instance arguments to run the linklet body
                 importss       ; list [length is 1 less than proc arity] of list of symbols
                 exports)       ; list of symbols
        #:prefab)

(struct instance (name        ; for debugging, typically a module name + phase
                  data        ; any value (e.g., a namespace)
                  variables)) ; symbol -> value

(define (make-instance name [data #f])
  (instance name data (make-hasheq)))

(define (instance-variable-names i)
  (hash-keys (instance-variables i)))

(define (instance-variable-box i sym can-create?)
  (or (hash-ref (instance-variables i) sym #f)
      (if can-create?
          (let ([b (box undefined)])
            (hash-set! (instance-variables i) sym b)
            b)
          (error 'link "missing binding: ~s" sym))))

(define (instance-set-variable-value! i sym val)
  (set-box! (instance-variable-box i sym #t) val))

(define (instance-unset-variable! i sym)
  (set-box! (instance-variable-box i sym #t) undefined))

(define (instance-variable-value i sym [fail-k (lambda () (error "instance variable not found:" sym))])
  (define b (hash-ref (instance-variables i) sym #f))
  (cond
   [(and b
         (not (eq? (unbox b) undefined)))
    (unbox b)]
   [(procedure? fail-k) (fail-k)]
   [else fail-k]))

;; ----------------------------------------

(define undefined (gensym 'undefined))

(define (check-not-undefined val sym)
  (if (eq? val undefined)
      (check-not-unsafe-undefined unsafe-undefined sym)
      val))

;; ----------------------------------------

(define (primitive-table name)
  (cond
   [(eq? name '#%bootstrap-linklet) #f]
   [(eq? name '#%linklet) (linklet-operations=> reflect-hash)]
   [else
    (define mod-name `(quote ,name))
    (define-values (vars trans) (module->exports mod-name))
    (for/hasheq ([sym (in-list (map car (cdr (assv 0 vars))))])
      (values sym
              (dynamic-require mod-name sym)))]))

;; ----------------------------------------

(struct variable-reference (instance primitive-varref))

(define (variable-reference->instance vr)
  (variable-reference-instance vr))

(define variable-reference-constant?*
  (let ([variable-reference-constant?
         (lambda (vr)
           (variable-reference-constant? (variable-reference-primitive-varref vr)))])
    variable-reference-constant?))

;; ----------------------------------------

(define cu-namespace (make-empty-namespace))
(namespace-attach-module (current-namespace) ''#%builtin cu-namespace)
(parameterize ([current-namespace cu-namespace])
  (for ([name (in-list runtime-instances)])
    (namespace-require `',name))
  (namespace-require ''#%linklet)
  (namespace-set-variable-value! 'check-not-undefined check-not-undefined)
  (namespace-set-variable-value! 'instance-variable-box instance-variable-box)
  (namespace-set-variable-value! 'variable-reference variable-reference)
  (namespace-set-variable-value! 'variable-reference? variable-reference? #t)
  (namespace-set-variable-value! 'variable-reference->instance variable-reference->instance #t)
  (namespace-set-variable-value! 'variable-reference-constant? variable-reference-constant?* #t))

;; ----------------------------------------

(define (desugar-linklet c)
  (define imports (list-ref c 1))
  (define exports (list-ref c 2))
  (define bodys (list-tail c 3))
  (define inst-names (for/list ([import (in-list imports)]
                                [i (in-naturals)])
                       (string->symbol (format "in_~a" i))))
  (define import-box-bindings
    (for/list ([inst-imports (in-list imports)]
               [inst (in-list inst-names)]
               #:when #t
               [name (in-list inst-imports)])
      (define ext (if (symbol? name) name (car name)))
      (define int (if (symbol? name) name (cadr name)))
      `[(,int) (instance-variable-box ,inst ',ext #f)]))
  (define export-box-bindings
    (for/list ([name (in-list exports)])
      (define int (if (symbol? name) name (car name)))
      (define ext (if (symbol? name) name (cadr name)))
      `[(,int) (instance-variable-box self-inst ',ext #t)]))
  (define box-bindings (append import-box-bindings export-box-bindings))
  (define import-box-syms (apply seteq (map caar import-box-bindings)))
  (define box-syms (set-union import-box-syms
                              (apply seteq (map caar export-box-bindings))))
  (define (desugar e)
    (cond
     [(correlated? e)
      (correlate e (desugar (correlated-e e)))]
     [(symbol? e) (if (set-member? box-syms e)
                      (if (set-member? import-box-syms e)
                          `(unbox ,e)
                          `(check-not-undefined (unbox ,e) ',e))
                      e)]
     [(pair? e)
      (case (correlated-e (car e))
        [(quote) e]
        [(set!)
         (define m (match-correlated e '(set! var rhs)))
         (if (set-member? box-syms (correlated-e (m 'var)))
             `(set-box! ,(m 'var) ,(desugar (m 'rhs)))
             `(set! ,(m 'var) ,(desugar (m 'rhs))))]
        [(define-values)
         (define m (match-correlated e '(define-values (id ...) rhs)))
         (define ids (m 'id))
         (define tmps (map gensym ids))
         `(define-values ,(for/list ([id (in-list ids)]
                                     #:when (not (set-member? box-syms (correlated-e id))))
                            id)
           (let-values ([,tmps (let-values ([,ids ,(desugar (m 'rhs))])
                                 (values ,@ids))])
             (begin
               ,@(for/list ([id (in-list ids)]
                            [tmp (in-list tmps)]
                            #:when (set-member? box-syms (correlated-e id)))
                   `(set-box! ,id ,tmp))
               (values ,@(for/list ([id (in-list ids)]
                                    [tmp (in-list tmps)]
                                    #:when (not (set-member? box-syms (correlated-e id))))
                           tmp)))))]
        [(lambda)
         (define m (match-correlated e '(lambda formals body)))
         `(lambda ,(m 'formals) ,(desugar (m 'body)))]
        [(case-lambda)
         (define m (match-correlated e '(case-lambda [formals body] ...)))
         `(case-lambda ,@(for/list ([formals (in-list (m 'formals))]
                               [body (in-list (m 'body))])
                      `[,formals ,(desugar body)]))]
        [(#%variable-reference)
         (if (and (pair? (correlated-e (cdr (correlated-e e))))
                  (set-member? box-syms (correlated-e (correlated-cadr e))))
             ;; Using a plain `#%variable-reference` (for now) means
             ;; that all imported and exported variables count as
             ;; mutable:
             '(variable-reference self-inst (#%variable-reference))
             ;; Preserve info about a local identifier:
             `(variable-reference self-inst ,e))]
        [else (map desugar (correlated->list e))])]
     [else e]))
  (define (last-is-definition? bodys)
    (define p (car (reverse bodys)))
    (and (pair? p) (eq? (correlated-e (car p)) 'define-values)))
  `(lambda (self-inst ,@inst-names)
    (let-values ,box-bindings
      ,(cond
        [(null? bodys) '(void)]
        [else
         `(begin
           ,@(for/list ([body (in-list bodys)])
               (desugar body))
           ,@(if (last-is-definition? bodys)
                 '((void))
                 null))]))))

;; #:pairs? #f -> list of list of symbols
;; #:pairs? #t -> list of list of (cons ext-symbol int-symbol)
(define (extract-import-variables-from-expression c #:pairs? pairs?)
  (for/list ([is (in-list (unmarshal (list-ref c 1)))])
    (for/list ([i (in-list is)])
      (cond 
       [pairs? (if (symbol? i)
                   (cons i i)
                   (cons (car i) (cadr i)))]
       [else (if (symbol? i)
                 i
                 (car i))]))))

;; #:pairs? #f -> list of symbols
;; #:pairs? #t -> list of (cons ext-symbol int-symbol)
(define (extract-export-variables-from-expression c #:pairs? pairs?)
  (for/list ([e (in-list (unmarshal (list-ref c 2)))])
    (cond
     [pairs? (if (symbol? e)
                 (cons e e)
                 (cons (cadr e) (car e)))]
     [else (if (symbol? e)
               e
               (cadr e))])))

;; ----------------------------------------

(define orig-eval (current-eval))
(define orig-compile (current-compile))

(define linklet-compile-to-s-expr (make-parameter #f))

;; Compile to a serializable form
(define (compile-linklet c)
  (cond
   [(linklet-compile-to-s-expr)
    (marshal (correlated->datum c))]
   [else
    (define plain-c (desugar-linklet c))
    (parameterize ([current-namespace cu-namespace]
                   [current-eval orig-eval]
                   [current-compile orig-compile])
      ;; Use a vector to list the exported variables
      ;; with the compiled bytecode
      (linklet (compile plain-c)
               (marshal (extract-import-variables-from-expression c #:pairs? #f))
               (marshal (extract-export-variables-from-expression c #:pairs? #f))))]))

;; Convert serializable form to instantitable form
(define (eval-linklet cl)
  (parameterize ([current-namespace cu-namespace]
                 [current-eval orig-eval]
                 [current-compile orig-compile])
    (if (linklet? cl)
        ;; Normal mode: compiled to struct
        (eval (linklet-compiled-proc cl))
        ;; Assume previously "compiled" to source:
        (or (hash-ref eval-cache cl #f)
            (let ([proc (eval (desugar-linklet (unmarshal cl)))])
              (hash-set! eval-cache cl proc)
              proc)))))
(define eval-cache (make-weak-hasheq))

;; Check whether we previously compiled a linket to source
(define (linklet-as-s-expr? cl)
  (not (linklet? cl)))

;; Instantiate
(define instantiate-linklet
  (case-lambda
    [(linklet import-instances)
     ;; 2-argument case: return instance
     (define target-instance (make-instance 'anonymous))
     (instantiate-linklet linklet import-instances target-instance)
     target-instance]
    [(linklet import-instances target-instance)
     ;; 3-argument case: return results via tail call
     (apply (eval-linklet linklet) target-instance import-instances)]))

;; ----------------------------------------

(define (linklet-import-variables linklet)
  (if (linklet? linklet)
      ;; Compiled to a prefab that includes metadata
      (linklet-importss linklet)
      ;; Previously "compiled" to source
      (extract-import-variables-from-expression linklet #:pairs? #f)))

(define (linklet-export-variables linklet)
  (if (linklet? linklet)
      ;; Compiled to a prefab that includes metadata
      (linklet-exports linklet)
      ;; Previously "compiled" to source
      (extract-export-variables-from-expression linklet #:pairs? #f)))

(define (s-expr-linklet-importss+localss linklet)
  (extract-import-variables-from-expression linklet #:pairs? #t))

(define (s-expr-linklet-exports+locals linklet)
  (extract-export-variables-from-expression linklet #:pairs? #t))

(define (s-expr-linklet-body linklet)
  (unmarshal (list-tail linklet 3)))

;; ----------------------------------------

(struct linklet-directory (table)
        #:prefab)

(define (hash->linklet-directory ht)
  (linklet-directory ht))

(define (linklet-directory->hash ld)
  (linklet-directory-table ld))

;; ----------------------------------------

(struct linklet-bundle (table)
        #:prefab)

(define (hash->linklet-bundle ht)
  (linklet-bundle ht))

(define (linklet-bundle->hash ld)
  (linklet-bundle-table ld))

;; ----------------------------------------

(struct path-bytes (bstr) #:prefab)
(struct unreadable (str) #:prefab)
(struct void-value () #:prefab)

(define (marshal c)
  (datum-map c (lambda (tail? c)
                 (cond
                  [(path? c) (path-bytes (path->bytes c))]
                  [(and (symbol? c) (symbol-unreadable? c)) (unreadable (symbol->string c))]
                  [(void? c) (void-value)]
                  [else c]))))

(define (unmarshal c)
  (datum-map c
             (lambda (tail? c)
               (cond
                [(path-bytes? c) (bytes->path (path-bytes-bstr c))]
                [(unreadable? c) (string->unreadable-symbol (unreadable-str c))]
                [(void-value? c) (void)]
                [else c]))))