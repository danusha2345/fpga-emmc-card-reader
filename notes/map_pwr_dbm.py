import struct
import sys
from collections import Counter

# 0.2 dBm per unit
# 156 (0x9C) -> 31.2 dBm
# 115 (0x73) -> 23.0 dBm
# 60  (0x3C) -> 12.0 dBm

def parse_pwr_map(filename):
    with open(filename, 'rb') as f:
        data = f.read()

    print(f"File: {filename} ({len(data)} bytes)")
    print("-" * 60)
    print(f"{'Block ID':<10} | {'Offset':<10} | {'Size':<8} | {'Header v1 (dBm)':<15} | {'Content Sample (dBm)'}")
    print("-" * 60)

    # Scan header table again to get blocks
    offset = 0
    header_count = 0
    
    # We deduced header table entries are 20 bytes
    # But let's just hardcode the known correct offsets from previous run if possible
    # Actually, simpler: Scan for 'BJ' signatures in first 512 bytes
    
    blocks = []
    
    for i in range(0, 1024, 1): # Scan first 1KB for headers
        if data[i:i+2] == b'BJ':
             # Unpack
            try:
                # rec_data = data[i:i+20]
                # magic, rec_id, v1, v2, v3, v4 = struct.unpack('<HHIIII', rec_data)
                
                # Based on previous robust unpack:
                # v2 was offset? No, v2 in header showed 0, 8192, 16384...
                # v1 was 115 (0x73)
                
                # Re-parse carefully
                rec_id = struct.unpack('<H', data[i+2:i+4])[0]
                v1     = struct.unpack('<I', data[i+4:i+8])[0]
                v2     = struct.unpack('<I', data[i+8:i+12])[0]
                v3     = struct.unpack('<I', data[i+12:i+16])[0]
                
                blocks.append({
                    'id': rec_id,
                    'offset': v2, # Assuming v2 is offset
                    'size': v3,   # Assuming v3 is size
                    'v1': v1,
                    'file_offset': i
                })
            except:
                pass
    
    # Process blocks
    for b in blocks:
        # Check logic: v2 is offset relative to what?
        # Header ID 0101 had v2=0. But we saw data at 0x160?
        # Header ID 0201 had v2=8192.
        # Maybe v2 is absolute offset.
        
        # In header 0101 (Offset 0x34): v2=0.
        # But data for block 1 seemed to be at 0x200?
        # Maybe Block 0 is the file header itself?
        
        # Let's assume v2 is the start of the block.
        # Sample data from middle of block
        
        sample_off = b['offset'] + 256 # Skip header/preamble of block
        if sample_off >= len(data): continue
        
        # read 64 bytes
        sample = data[sample_off : sample_off+64]
        
        # Find most common byte
        c = Counter(sample)
        most_common_byte = c.most_common(1)[0][0]
        
        # Convert to dBm
        dbm_header = (b['v1'] / 5.0)
        dbm_content = (most_common_byte / 5.0)
        
        # Region assumption
        region = "?"
        if rec_id == 0x0101: region = "FCC/2.4?"
        
        print(f"0x{b['id']:04X}     | 0x{b['offset']:05X}    | {b['size']:<8} | {dbm_header:>5.1f} dBm       | {most_common_byte:3d} (0x{most_common_byte:02X}) -> {dbm_content:>4.1f} dBm")

if __name__ == "__main__":
    parse_pwr_map("/mnt/dump_vendor/modem_firmware/sparrow2/pwr.bin")
