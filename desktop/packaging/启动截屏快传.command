#!/bin/sh
cd "$(dirname "$0")" || exit 1
./ScreenRelay
status=$?
if [ "$status" -ne 0 ]; then
    printf '\n接收器未能运行。请查看上方错误。按回车键关闭。\n'
    read -r ignored
fi
exit "$status"
