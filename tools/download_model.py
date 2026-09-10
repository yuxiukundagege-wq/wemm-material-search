# -*- coding: utf-8 -*-
"""WeMM-Embedding-4B 权重下载器（幂等 / 断点续传 / 国内镜像）

用法:
    python download_model.py --dir D:\\WeMM-Embedding\\models\\WeMM-Embedding-4B
    python download_model.py --dir <模型目录> --check-only     # 只检查本地完整性，不联网

关键环境变量（本脚本内部强制设置，外部传入可覆盖）:
    HF_ENDPOINT=https://hf-mirror.com    走国内镜像站，避免直连 huggingface.co
    HF_HUB_DISABLE_XET=1                 关闭 xet 传输通道（不关会在大文件下载时卡死）
    HF_HUB_ENABLE_HF_TRANSFER=0          不使用 hf_transfer

返回码: 0=已就绪(含本次下载完成)  2=本地不完整且仅检查  3=下载失败(可重跑续传)
"""
import argparse
import json
import os
import sys

try:
    sys.stdout.reconfigure(encoding='utf-8')
    sys.stderr.reconfigure(encoding='utf-8')
except Exception:
    pass


def ensure_env():
    os.environ.setdefault('HF_ENDPOINT', 'https://hf-mirror.com')
    os.environ['HF_HUB_DISABLE_XET'] = '1'
    os.environ['HF_HUB_ENABLE_HF_TRANSFER'] = '0'


class _Tee(object):
    """把 print 的内容同时写到控制台和日志文件（进度条走 stderr，仍在控制台实时显示）。"""

    def __init__(self, primary, secondary):
        self.primary = primary
        self.secondary = secondary

    def write(self, s):
        try:
            self.primary.write(s)
            self.primary.flush()
        except Exception:
            pass
        try:
            self.secondary.write(s)
            self.secondary.flush()
        except Exception:
            pass
        return len(s)

    def flush(self):
        for st in (self.primary, self.secondary):
            try:
                st.flush()
            except Exception:
                pass

    def isatty(self):
        try:
            return self.primary.isatty()
        except Exception:
            return False


def verify(model_dir, manifest):
    """返回 (缺失列表, 大小不符列表, 已有字节数, 总字节数)"""
    missing, mismatch, have, total = [], [], 0, 0
    for name, size in manifest['files'].items():
        p = os.path.join(model_dir, name)
        total += size
        if not os.path.isfile(p):
            missing.append(name)
            continue
        real = os.path.getsize(p)
        if size and real != size:
            mismatch.append('%s(本地%.1fMB/应为%.1fMB)' % (name, real / 1024 ** 2, size / 1024 ** 2))
            have += real
        else:
            have += real
    return missing, mismatch, have, total


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--dir', required=True, help='模型权重目标目录')
    ap.add_argument('--repo', default='tencent/WeMM-Embedding-4B')
    ap.add_argument('--manifest', default=os.path.join(os.path.dirname(os.path.abspath(__file__)), 'model_manifest.json'))
    ap.add_argument('--workers', type=int, default=8)
    ap.add_argument('--check-only', action='store_true')
    ap.add_argument('--log', default='', help='同时把日志写入该文件(UTF-8, 追加)')
    a = ap.parse_args()

    ensure_env()
    if a.log:
        try:
            _f = open(a.log, 'a', encoding='utf-8')
            sys.stdout = _Tee(sys.stdout, _f)
        except Exception as ex:
            print('WARN 无法写入日志文件 %s : %r' % (a.log, ex))
    model_dir = os.path.abspath(a.dir)
    manifest = json.load(open(a.manifest, encoding='utf-8'))

    missing, mismatch, have, total = verify(model_dir, manifest)
    if not missing and not mismatch:
        print('MODEL_ALREADY_OK %s (%d 个文件, %.2fGB 已完整)' % (model_dir, len(manifest['files']), have / 1024 ** 3))
        return 0

    print('MODEL_INCOMPLETE 缺失 %d 个文件, 大小不符 %d 个; 本地已有 %.2fGB / 共 %.2fGB'
          % (len(missing), len(mismatch), have / 1024 ** 3, total / 1024 ** 3))
    for m in (missing[:5] + mismatch[:5]):
        print('   - %s' % m)
    if a.check_only:
        return 2

    os.makedirs(model_dir, exist_ok=True)
    print('开始从 %s 下载 %s （支持断点续传，中断后重跑本脚本即可继续）' % (os.environ['HF_ENDPOINT'], a.repo))
    try:
        from huggingface_hub import snapshot_download
    except Exception as ex:
        print('FAIL 缺少 huggingface_hub: %r' % ex)
        return 3

    try:
        path = snapshot_download(
            repo_id=a.repo,
            local_dir=model_dir,
            max_workers=a.workers,
            etag_timeout=30,
        )
        print('下载返回目录: %s' % path)
    except KeyboardInterrupt:
        print('FAIL 已被用户中断，重跑本脚本可继续下载（不会从头开始）')
        return 3
    except Exception as ex:
        print('FAIL 下载失败: %r' % ex)
        print('提示: 可重跑本脚本续传；若反复失败请检查网络/代理，或改用其它镜像。')
        return 3

    missing, mismatch, have, total = verify(model_dir, manifest)
    if missing or mismatch:
        print('FAIL 下载后校验仍未通过: 缺失 %d 个, 大小不符 %d 个' % (len(missing), len(mismatch)))
        for m in (missing[:5] + mismatch[:5]):
            print('   - %s' % m)
        return 3
    print('MODEL_READY %s (%d 个文件, %.2fGB 校验通过)' % (model_dir, len(manifest['files']), have / 1024 ** 3))
    return 0


if __name__ == '__main__':
    sys.exit(main())
