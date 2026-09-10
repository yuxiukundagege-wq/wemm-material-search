# -*- coding: utf-8 -*-
"""打印当前 Python 的 major.minor 版本，供一键部署脚本检测解释器是否可用。

之所以单独做成文件而不是用 python -c "..."，是因为 PowerShell 5.1
向原生 exe 传参时会吞掉内层双引号，导致内联代码被破坏。
"""
import sys

sys.stdout.write('%d.%d' % (sys.version_info[0], sys.version_info[1]))
