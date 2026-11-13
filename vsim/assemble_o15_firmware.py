import argparse
import re
import struct
from pathlib import Path

REGISTERS = {
    "zero": 0, "ra": 1, "sp": 2, "gp": 3, "tp": 4,
    "t0": 5, "t1": 6, "t2": 7, "s0": 8, "s1": 9,
    "a0": 10, "a1": 11, "a2": 12, "a3": 13,
    "a4": 14, "a5": 15, "a6": 16, "a7": 17,
    "s2": 18, "s3": 19, "s4": 20, "s5": 21,
    "s6": 22, "s7": 23, "s8": 24, "s9": 25,
    "s10": 26, "s11": 27, "t3": 28, "t4": 29,
    "t5": 30, "t6": 31,
}

def _reg(name):
    name = name.strip()
    if name in REGISTERS:
        return REGISTERS[name]
    if re.fullmatch(r"x(?:[0-9]|[12][0-9]|3[01])", name):
        return int(name[1:])
    raise ValueError("Unknown register: " + name)

def _imm(value):
    return int(value.strip(), 0)

def _operands(line):
    mnemonic, _, rest = line.partition(" ")
    return mnemonic.lower(), [item.strip() for item in rest.split(",")]

def _memory_operand(value):
    match = re.fullmatch(r"(-?(?:0x[0-9a-fA-F]+|[0-9]+))\((\w+)\)", value.strip())
    if not match:
        raise ValueError("Invalid memory operand: " + value)
    return int(match.group(1), 0), _reg(match.group(2))

def _signed(value, bits):
    if value < -(1 << (bits - 1)) or value >= (1 << (bits - 1)):
        raise ValueError(f"Immediate {value} does not fit signed {bits}-bit field")
    return value & ((1 << bits) - 1)

def _source(source):
    labels = {}
    instructions = []
    pc = 0
    for line_number, raw in enumerate(source.splitlines(), 1):
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        if ":" in line:
            label, _, line = line.partition(":")
            if label in labels:
                raise ValueError(f"Duplicate label on line {line_number}: {label}")
            labels[label.strip()] = pc
            line = line.strip()
        if not line or line.startswith("."):
            continue
        instructions.append((pc, line, line_number))
        pc += 4
    return labels, instructions

def _encode(line, pc, labels):
    mnemonic, operands = _operands(line)
    if mnemonic == "fence":
        return 0x0FF0000F
    if mnemonic == "lui":
        rd, immediate = _reg(operands[0]), _imm(operands[1])
        if immediate < -(1 << 19) or immediate > 0xFFFFF:
            raise ValueError("LUI immediate does not fit 20 bits")
        return ((immediate & 0xFFFFF) << 12) | (rd << 7) | 0x37
    if mnemonic in ("lw", "lhu"):
        rd = _reg(operands[0])
        immediate, rs1 = _memory_operand(operands[1])
        funct3 = 2 if mnemonic == "lw" else 5
        return (_signed(immediate, 12) << 20) | (rs1 << 15) | (funct3 << 12) | (rd << 7) | 0x03
    if mnemonic == "sw":
        rs2 = _reg(operands[0])
        immediate, rs1 = _memory_operand(operands[1])
        imm = _signed(immediate, 12)
        return (((imm >> 5) << 25) | (rs2 << 20) | (rs1 << 15) | (2 << 12)
                | ((imm & 0x1F) << 7) | 0x23)
    if mnemonic in ("addi", "andi", "slli", "srli"):
        rd, rs1, immediate = _reg(operands[0]), _reg(operands[1]), _imm(operands[2])
        funct3 = {"addi": 0, "andi": 7, "slli": 1, "srli": 5}[mnemonic]
        if mnemonic in ("slli", "srli"):
            if immediate < 0 or immediate > 31:
                raise ValueError("Shift amount does not fit 5 bits")
            imm = immediate
        else:
            imm = _signed(immediate, 12)
        return (imm << 20) | (rs1 << 15) | (funct3 << 12) | (rd << 7) | 0x13
    if mnemonic in ("add", "or"):

        rd, rs1, rs2 = _reg(operands[0]), _reg(operands[1]), _reg(operands[2])
        funct3 = 0 if mnemonic == "add" else 6
        return (rs2 << 20) | (rs1 << 15) | (funct3 << 12) | (rd << 7) | 0x33
    if mnemonic in ("beq", "bne"):
        rs1, rs2 = _reg(operands[0]), _reg(operands[1])
        if operands[2] not in labels:
            raise ValueError("Unknown branch label: " + operands[2])
        offset = labels[operands[2]] - pc
        if offset & 1:
            raise ValueError("Branch target is not halfword aligned")
        imm = _signed(offset, 13)
        funct3 = 0 if mnemonic == "beq" else 1
        return (((imm >> 12) << 31) | (((imm >> 5) & 0x3F) << 25)
                | (rs2 << 20) | (rs1 << 15) | (funct3 << 12)
                | (((imm >> 1) & 0xF) << 8) | (((imm >> 11) & 1) << 7) | 0x63)
    if mnemonic == "jal":
        rd = _reg(operands[0])
        if operands[1] not in labels:
            raise ValueError("Unknown jump label: " + operands[1])
        offset = labels[operands[1]] - pc
        if offset & 1:
            raise ValueError("Jump target is not halfword aligned")
        imm = _signed(offset, 21)
        return (((imm >> 20) << 31) | (((imm >> 1) & 0x3FF) << 21)
                | (((imm >> 11) & 1) << 20) | (((imm >> 12) & 0xFF) << 12)
                | (rd << 7) | 0x6F)
    raise ValueError("Unsupported instruction: " + mnemonic)

def assemble(source):
    labels, instructions = _source(source)
    output = bytearray()
    for pc, line, line_number in instructions:
        try:
            output.extend(struct.pack("<I", _encode(line, pc, labels)))
        except ValueError as error:
            raise ValueError(f"Line {line_number}: {error}") from error
    return bytes(output)

def read_verilog(text):
    output = bytearray()
    for token in text.split():
        if token.startswith("@"):
            continue
        value = int(token, 16)
        if value > 0xFF:
            raise ValueError("Expected one byte in Verilog memory image: " + token)
        output.append(value)
    return bytes(output)

def write_verilog(image, path):
    lines = ["@00000000"]
    for index in range(0, len(image), 16):
        lines.append(" ".join(f"{byte:02X}" for byte in image[index:index + 16]))
    Path(path).write_text("\n".join(lines) + "\n", encoding="ascii")

def main():
    parser = argparse.ArgumentParser(description="Assemble the RV32I instructions used by O15 test firmware.")
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    image = assemble(args.source.read_text(encoding="ascii"))
    write_verilog(image, args.output)
    print(f"assembled {len(image) // 4} RV32I instructions ({len(image)} bytes)")

if __name__ == "__main__":
    main()
