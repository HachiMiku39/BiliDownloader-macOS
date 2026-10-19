@echo off
python -m nuitka ^
--enable-plugins=pyside6 ^
--standalone ^
--windows-uac-admin ^
--user-package-configuration-file=nuitka_config/bili_api.nuitka-package.config.yaml ^
--output-dir=dist.nuitka.test ^
--output-filename=BiliDownloader.exe ^
--jobs=16 ^
main.py