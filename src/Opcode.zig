//! Internal opcode
//! Can represent Brainfuck opcodes directly but also supports
//! extended and more powerful opcodes generated by the various
//! optimization passes.

pub const Instruction = struct {
    /// Optimization: Cell offset to perform operations relative
    /// to the current cell without an extra move operation.
    off: isize,
    op: union(enum) {
        /// One or more + or - (increment/decrement cell content)
        add: isize,
        /// One or more > or < (change pointer to current cell)
        move: isize,
        /// .
        print,
        /// ,
        read,
        /// [ (address of matching ])
        jump_forward: usize,
        /// ] (address of matching [)
        jump_back: usize,
        /// Optimization: Set cell to value
        set: isize,
        /// Optimization: Multiply-accumulate relative to the current cell.
        /// This is a strange operation but it seems to be heavily used by
        /// some larger Brainfuck applications, e.g. LostKingdom.b
        /// cell[current + offset] += cell[current + off] * multiplier
        mac: struct { offset: isize, multiplier: isize },
    },
};
