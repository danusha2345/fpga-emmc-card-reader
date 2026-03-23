import struct
import sys

def parse_pwr_bin(filename):
    with open(filename, 'rb') as f:
        data = f.read()

    if data[0:4] != b'SDRH':
        print("Invalid Magic Header")
        return

    # Header analysis
    # 0x00: SDRH
    # ...
    
    print(f"File size: {len(data)} bytes")
    
    # Scan for frequency patterns (LE & BE, MHz & kHz)
    print("Scanning for Frequency/Power patterns (LE/BE, MHz/kHz)...")
    
    for i in range(0, len(data) - 16, 4):
        # Little Endian
        val_le = struct.unpack('<I', data[i:i+4])[0]
        # Big Endian
        val_be = struct.unpack('>I', data[i:i+4])[0]
        
        matches = []
        if (2400 <= val_le <= 2500): matches.append(f"LE MHz: {val_le}")
        if (5700 <= val_le <= 5900): matches.append(f"LE MHz: {val_le}")
        
        if (2400000 <= val_le <= 2500000): matches.append(f"LE kHz: {val_le}")
        if (5700000 <= val_le <= 5900000): matches.append(f"LE kHz: {val_le}")

        if (2400 <= val_be <= 2500): matches.append(f"BE MHz: {val_be}")
        if (5700 <= val_be <= 5900): matches.append(f"BE MHz: {val_be}")
        
        if matches:
            context = data[i:i+16]
            v1, v2, v3, v4 = struct.unpack('<IIII', context) # Print context in LE
            print(f"[@0x{i:05X}] Found: {', '.join(matches)}")
            print(f"   Context (LE): {v1} {v2} {v3} {v4}")
            print(f"   Hex: {context.hex()}")
            print("-" * 20)

if __name__ == "__main__":
    parse_pwr_bin("/mnt/dump_vendor/modem_firmware/sparrow2/pwr.bin")
