#!/bin/bash

# 获取当前日期
DATE=$(date +%Y-%-m-%-d)

# 提示用户输入 commit 标题
read -p "请输入 commit 标题: " TITLE

# 拼接 commit message
MESSAGE="$DATE-\"$TITLE\""

# 执行 git 操作
git add .
git commit -m "$MESSAGE"
git push