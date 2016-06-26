#lang racket/base
(require (for-syntax racket/base))

(provide linklet-operations=>)

(define-syntax (linklet-operations=> stx)
  (syntax-case stx ()
    [(_ form)
     (datum->syntax
      #'form
      (cons #'form
            '(primitive-table
              
              linklet?
              compile-linklet             ; result is serializable
              instantiate-linklet         ; fills in an instance given argument instances
              
              linklet-import-variables
              linklet-export-variables

              instance?
              make-instance
              instance-name               ; just for debugging and similar
              instance-data
              instance-variable-names
              instance-variable-value
              instance-set-variable-value!
              instance-unset-variable!

              linklet-directory?       ; maps symbol lists to linklet bundles
              hash->linklet-directory  ; converts a hash table to a ld
              linklet-directory->hash  ; the other way

              linklet-bundle?          ; maps symbols and fixnums to values
              hash->linklet-bundle
              linklet-bundle->hash
              
              variable-reference?
              variable-reference->instance
              variable-reference-constant?)))]))