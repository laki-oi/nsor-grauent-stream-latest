import os
import sys
import subprocess
import tarfile

try:
    import zstandard as zstd
except ImportError:
    zstd = None

def main():
    repo = os.environ.get('HF_REPO')
    token = os.environ.get('HF_TOKEN')
    env_pass = os.environ.get('ENV_PASS')

    if not repo or not token or not env_pass:
        print("[Hydrate] Notice: Missing HF credentials or encryption key. Initializing baseline layer.")
        return

    os.environ['HF_HUB_ENABLE_HF_TRANSFER'] = '1'

    from huggingface_hub import hf_hub_download

    temp_dir = 'C:/Temp'
    os.makedirs(temp_dir, exist_ok=True)
    enc_blob = os.path.join(temp_dir, 'windows-user-layer.bin')
    tar_zst = os.path.join(temp_dir, 'windows-user-layer.tar.zst')

    try:
        print(f"[Hydrate] Fetching state matrix from Hugging Face ({repo})...")
        hf_hub_download(
            repo_id=repo,
            filename='windows-user-layer.bin',
            repo_type='dataset',
            token=token,
            local_dir=temp_dir
        )
        print("[Hydrate] Remote state matrix fetched successfully.")
    except Exception as e:
        print(f"[Hydrate] Baseline initialization: No remote checkpoint layer found ({e}).")
        return

    if not os.path.exists(enc_blob):
        print("[Hydrate] Remote layer blob missing on disk.")
        return

    print("[Hydrate] Decrypting state layer (AES-256-CBC PBKDF2)...")
    openssl = r"C:\Program Files\Git\usr\bin\openssl.exe"
    if not os.path.exists(openssl):
        openssl = "openssl"

    cmd = [
        openssl, "enc", "-d", "-aes-256-cbc", "-pbkdf2",
        "-pass", f"pass:{env_pass}",
        "-in", enc_blob,
        "-out", tar_zst
    ]
    res = subprocess.run(cmd, capture_output=True)
    if res.returncode != 0:
        print(f"[Hydrate] Decryption failed: {res.stderr.decode(errors='ignore')}")
        return

    try:
        os.remove(enc_blob)
    except OSError:
        pass

    if not os.path.exists(tar_zst):
        print("[Hydrate] Decrypted archive not found.")
        return

    print("[Hydrate] Unpacking state archive to native filesystem...")
    dctx = zstd.ZstdDecompressor()
    extracted_count = 0
    with open(tar_zst, 'rb') as f_in:
        with dctx.stream_reader(f_in) as decompressor:
            with tarfile.open(fileobj=decompressor, mode='r|') as tar:
                for member in tar:
                    try:
                        if hasattr(tarfile, 'fully_trusted_filter'):
                            tar.extract(member, path='C:/', filter='fully_trusted')
                        else:
                            tar.extract(member, path='C:/')
                        extracted_count += 1
                    except Exception:
                        pass

    print(f"[Hydrate] Successfully unpacked {extracted_count} state items to native paths.")

    try:
        os.remove(tar_zst)
    except OSError:
        pass

    reg_file = r"C:\Temp\user_settings.reg"
    if os.path.exists(reg_file):
        print("[Hydrate] Importing restored user registry hive...")
        subprocess.run(["reg.exe", "import", reg_file], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            os.remove(reg_file)
        except OSError:
            pass

    print("[Hydrate] State matrix synchronization complete.")

if __name__ == '__main__':
    main()
