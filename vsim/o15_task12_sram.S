    .section .text
    .option norvc
    .globl _start
_start:
    lui   a0, 0x10042
    lw    t0, 0(a0)
    lui   t1, 0x54415
    addi  t1, t1, 0x34b
    bne   t0, t1, fail

    lui   s2, 0x80001
    lui   s3, 0xA0000
    lui   s4, 0x2
cp_w1:
    lw    s5, 0(s2)
    sw    s5, 0(s3)
    addi  s2, s2, 4
    addi  s3, s3, 4
    addi  s4, s4, -1
    bne   s4, zero, cp_w1

    lui   s2, 0x80009
    lui   s3, 0xA0008
    addi  s4, zero, 128
cp_b1:
    lw    s5, 0(s2)
    sw    s5, 0(s3)
    addi  s2, s2, 4
    addi  s3, s3, 4
    addi  s4, s4, -1
    bne   s4, zero, cp_b1

    lui   s2, 0x80009
    addi  s2, s2, 0x200
    lui   s3, 0xA0010
    addi  s3, s3, 0x280
    lui   s4, 0x1
    addi  s4, s4, -928
cp_x:
    lw    s5, 0(s2)
    sw    s5, 0(s3)
    addi  s2, s2, 4
    addi  s3, s3, 4
    addi  s4, s4, -1
    bne   s4, zero, cp_x

    lui   t0, 0x8000F
wait_ctrl:
    lw    t1, 0(t0)
    beq   t1, zero, wait_ctrl
    addi  t1, t1, 4
    sw    t1, 8(a0)

    fence iorw, iorw

    addi  s0, zero, 0
    lui   s1, 0x6
    addi  s1, s1, 0x300
read_pairs:
    lw    t2, 20(a0)
    addi  s0, s0, 2
    bne   s0, s1, read_pairs

poll_done:
    lw    t0, 12(a0)
    andi  t1, t0, 4
    bne   t1, zero, fail
    andi  t1, t0, 2
    beq   t1, zero, poll_done
    andi  t1, t0, 0x1d
    bne   t1, zero, fail

    lw    t4, 24(a0)
    srli  t5, t4, 16
    bne   t5, zero, fail
    addi  x3, zero, 1
done:
    jal   zero, done

fail:
    addi  x3, zero, 0
    jal   zero, fail
