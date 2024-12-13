#!/usr/bin/env python3
import subprocess
from pathlib import Path

def fix_patch_content(content):
    content = content.replace('\r\n', '\n').replace('\r', '\n')
    
    lines = content.splitlines()
    
    header_lines = []
    diff_lines = []
    in_header = True
    
    for line in lines:
        if in_header:
            if line.startswith('---') or line.startswith('+++'):
                header_lines.append(line)
            elif line.startswith('@@'):
                in_header = False
                diff_lines.append(line)
        else:
            diff_lines.append(line)
    
    return '\n'.join(header_lines + diff_lines) + '\n'

def apply_patches():
    patches_dir = Path('./patches')
    
    if not patches_dir.exists():
        print(f"Error: {patches_dir} directory not found")
        return 1
        
    patch_files = sorted(patches_dir.glob('*.patch'))
    
    if not patch_files:
        print("No .patch files found in ./patches/")
        return 0
        
    for patch_file in patch_files:
        print(f"Applying patch: {patch_file}")
        try:
            with open(patch_file, 'r', encoding='utf-8-sig') as f:
                patch_content = fix_patch_content(f.read())
            
            temp_patch = patch_file.with_suffix('.tmp')
            with open(temp_patch, 'w', encoding='utf-8', newline='\n') as f:
                f.write(patch_content)
            
            result = subprocess.run(['git', 'apply', '--whitespace=fix', str(temp_patch)], 
                                 capture_output=True,
                                 text=True)
            
            if result.returncode != 0:
                result = subprocess.run(['git', 'apply', '--ignore-whitespace', str(temp_patch)],
                                     capture_output=True,
                                     text=True)
                                     
            if result.returncode != 0:
                print(f"Error applying {patch_file}:")
                print(result.stderr)
                if temp_patch.exists():
                    temp_patch.unlink()
                return 1
            
            temp_patch.unlink()
            print(f"✓ Successfully applied {patch_file}")
            
        except UnicodeDecodeError:
            print(f"Error: Unable to read {patch_file} - encoding issue")
            return 1
        except Exception as e:
            print(f"Error processing {patch_file}:")
            print(str(e))
            if 'temp_patch' in locals() and temp_patch.exists():
                temp_patch.unlink()
            return 1
            
    return 0

if __name__ == '__main__':
    exit(apply_patches())