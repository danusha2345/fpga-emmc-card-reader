import struct
import sys

# Raw bytes from 0x34a1c (duss_util_crc16_ccitt_calc) from previous hexdump
# 00034a1c  fa 67 44 a9 fc 6f 43 a9  ff 43 02 91 c0 03 5f d6
# 00034a2c  ff 03 01 d1 f5 0b 00 f9  f4 4f 02 a9 fd 7b 03 a9
# 00034a3c  fd c3 00 91 f5 03 01 2a  f3 03 00 aa 54 7d 80 12
# 00034a4c  b3 07 00 b4 bf 66 40 71  68 07 00 54 e0 07 1d 32
# 00034a5c  e1 03 00 32 80 a5 ff 97  60 0a 00 f9 a0 03 00 b4

code_bytes = bytes.fromhex("fa6744a9fc6f43a9ff430291c0035fd6ff0301d1f50b00f9f44f02a9fd7b03a9fdc30091f503012af30300aa547d8012b30700b4bf66407168070054e0071d32e103003280a5ff97600a00f9a00300b4")

def disassemble_rough(msg, data):
    print(f"Analyzing {msg}:")
    for i in range(0, len(data), 4):
        if i + 4 > len(data): break
        chunk = data[i:i+4]
        inst = struct.unpack('<I', chunk)[0] # Little endian
        
        # Check for MOVZ (Move Zero) with immediate 0x1021
        # MOVZ encoding: 32-bit: [sf(1) 10 10010 1 hw(2) imm16(16) Rd(5)]
        # 0x1021 = 0001 0000 0010 0001
        
        # Check for immediate 0x1021 in instruction
        if 0x1021 in [inst & 0xFFFF, (inst >> 16) & 0xFFFF]:
            print(f"Offset +{i:02x}: Found possible 0x1021 constant: {inst:08x}")

        # Check for ORR/EOR with immediate
        
        print(f"+{i:02x}: {inst:08x}")

disassemble_rough("CCITT Calc", code_bytes)
