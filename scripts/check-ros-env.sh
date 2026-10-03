#!/usr/bin/env bash
# 检查这台机器是否已经具备视觉导航所需的 ROS Noetic 环境。
set -u

ok() { printf '  [通过] %s\n' "$1"; }
bad() { printf '  [缺失] %s\n' "$1"; FAILED=1; }
note() { printf '  [说明] %s\n' "$1"; }

FAILED=0

echo "系统"
if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  source /etc/os-release
  if [[ "${VERSION_ID:-}" == "20.04" ]]; then
    ok "${PRETTY_NAME}"
  else
    bad "需要 Ubuntu 20.04，当前是 ${PRETTY_NAME:-未知}"
  fi
else
  bad "读不到 /etc/os-release"
fi

echo "区域设置"
if locale | grep -q 'UTF-8'; then
  ok "$(locale | awk -F= '/^LANG=/{print $2}')"
else
  bad "LANG 不是 UTF-8。执行：sudo locale-gen en_US.UTF-8 && sudo update-locale LANG=en_US.UTF-8"
fi

echo "ROS"
if [[ -f /opt/ros/noetic/setup.bash ]]; then
  # shellcheck disable=SC1091
  source /opt/ros/noetic/setup.bash
  ok "Noetic 已安装到 /opt/ros/noetic"
else
  bad "没有 /opt/ros/noetic/setup.bash"
fi

PACKAGES=(
  ros-noetic-desktop-full
  ros-noetic-gmapping
  ros-noetic-turtlebot3-gazebo
  ros-noetic-turtlebot3-navigation
  ros-noetic-rtabmap-launch
  ros-noetic-realsense2-camera
  ros-noetic-depthimage-to-laserscan
  ros-noetic-teb-local-planner
)
for pkg in "${PACKAGES[@]}"; do
  if dpkg -s "${pkg}" 2>/dev/null | grep -q '^Status: install ok installed$'; then
    ok "${pkg}"
  else
    bad "${pkg}"
  fi
done

echo "工作空间"
WS="${HOME}/marathongo"
if [[ -f "${WS}/devel/setup.bash" ]]; then
  ok "${WS}"
else
  bad "还没有 ${WS}/devel/setup.bash。先运行安装脚本，或在该目录执行 catkin_make"
fi

echo "网络与远程登录"
if command -v ip >/dev/null 2>&1; then
  mapfile -t ADDRS < <(ip -4 -o addr show scope global | awk '{print $2, $4}')
  if [[ ${#ADDRS[@]} -eq 0 ]]; then
    note "没有全局 IPv4 地址。远程连接需要网卡上的局域网地址，127.0.0.1 只能本机使用"
  else
    for item in "${ADDRS[@]}"; do
      ok "局域网地址 ${item}"
    done
  fi
else
  bad "没有 ip 命令"
fi

if systemctl is-active --quiet ssh 2>/dev/null; then
  ok "SSH 服务正在运行"
else
  note "SSH 未运行。需要远程终端时执行：sudo apt install openssh-server && sudo systemctl enable --now ssh"
fi

echo "相机"
if compgen -G "/dev/video*" > /dev/null; then
  ok "已发现 $(ls /dev/video* | tr '\n' ' ')"
else
  note "当前没有 /dev/video*。插入 USB 相机或 RealSense 后再检查"
fi

echo
if [[ "${FAILED}" -eq 0 ]]; then
  echo "环境检查通过。下一步可按 README 跑 turtlesim，再跑 TurtleBot3 仿真。"
else
  echo "还有缺失项。安装步骤见 README.md，或运行 scripts/setup-ubuntu2004-ros-noetic.sh"
  exit 1
fi
