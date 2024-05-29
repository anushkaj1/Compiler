(define (func [x : Integer] [y : Integer]) : Integer
    (let ([x2 x]) 
    (let ([y3 y])
        (+ (+ (begin
                (set! y3 4)
                x2) 
            (begin
                (set! x2 8)
                y3)) 
        x2))))
(func 5 4)