(define (func [int1 : Integer] [int2 : Integer]) : Integer
    (let ([x int1])
        (let ([y int2])
            (if (if (< x 1) (eq? x 0) (eq? x 2)) (+ y 2)
                (+ y 10)))))
(func 4 18)