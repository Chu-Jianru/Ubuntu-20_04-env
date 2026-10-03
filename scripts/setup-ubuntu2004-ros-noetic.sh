#!/usr/bin/env bash
# 在 Ubuntu 20.04 上安装 ROS Noetic，以及视觉导航会用到的软件包。
# 用普通用户运行：bash scripts/setup-ubuntu2004-ros-noetic.sh
set -euo pipefail

MIRROR="tuna"
UBUNTU_MIRROR="off"
WORKSPACE="${HOME}/marathongo"

usage() {
  cat <<'EOF'
用法：bash scripts/setup-ubuntu2004-ros-noetic.sh [选项]

选项：
  --mirror tuna|ustc|official   ROS 软件源，默认 tuna（清华）
  --ubuntu-mirror tuna|aliyun|off
                                是否把 Ubuntu 源换成国内镜像，默认 off
  --workspace PATH              catkin 工作空间，默认 ~/marathongo
  -h, --help                    显示这段说明

脚本只接受 Ubuntu 20.04。它会安装 ROS Noetic desktop-full、
TurtleBot3 仿真、RTAB-Map、RealSense 驱动和导航相关包。
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mirror)
      MIRROR="${2:?缺少镜像名称}"
      shift 2
      ;;
    --ubuntu-mirror)
      UBUNTU_MIRROR="${2:?缺少 Ubuntu 镜像名称}"
      shift 2
      ;;
    --workspace)
      WORKSPACE="${2:?缺少工作空间路径}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "无法识别的参数：$1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ "${EUID}" -eq 0 ]]; then
  echo "请用普通用户运行。需要管理员权限时，脚本会自己调用 sudo。" >&2
  exit 1
fi

if [[ ! -r /etc/os-release ]]; then
  echo "读不到 /etc/os-release，无法确认系统版本。" >&2
  exit 1
fi

# shellcheck disable=SC1091
source /etc/os-release
if [[ "${VERSION_ID:-}" != "20.04" ]]; then
  echo "当前系统是 ${PRETTY_NAME:-未知}。这份安装只适用于 Ubuntu 20.04。" >&2
  exit 1
fi

ARCH="$(dpkg --print-architecture)"
case "${ARCH}" in
  amd64|arm64|armhf) ;;
  *)
    echo "ROS Noetic 不提供 ${ARCH} 的安装包。" >&2
    exit 1
    ;;
esac

case "${MIRROR}" in
  tuna) ROS_URL="https://mirrors.tuna.tsinghua.edu.cn/ros/ubuntu/" ;;
  ustc) ROS_URL="https://mirrors.ustc.edu.cn/ros/ubuntu/" ;;
  official) ROS_URL="http://packages.ros.org/ros/ubuntu/" ;;
  *)
    echo "不支持的 ROS 镜像：${MIRROR}" >&2
    exit 1
    ;;
esac

echo "==> 安装基础工具并打开 Ubuntu 的 universe 仓库"
sudo apt-get update
sudo apt-get install -y \
  ca-certificates \
  curl \
  gnupg \
  lsb-release \
  software-properties-common \
  locales \
  git \
  build-essential \
  python3-pip \
  python3-rosdep \
  python3-rosinstall \
  python3-rosinstall-generator \
  python3-wstool \
  python3-catkin-tools \
  openssh-server \
  chrony \
  v4l-utils

sudo add-apt-repository -y universe
sudo add-apt-repository -y restricted
sudo add-apt-repository -y multiverse

if ! locale | grep -q 'LANG=.*UTF-8'; then
  echo "==> ROS 需要 UTF-8 区域设置，正在生成 en_US.UTF-8"
  sudo locale-gen en_US en_US.UTF-8
  sudo update-locale LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
  export LANG=en_US.UTF-8
fi

if [[ "${UBUNTU_MIRROR}" != "off" ]]; then
  case "${UBUNTU_MIRROR}" in
    tuna) UBUNTU_URL="https://mirrors.tuna.tsinghua.edu.cn" ;;
    aliyun) UBUNTU_URL="https://mirrors.aliyun.com" ;;
    *)
      echo "不支持的 Ubuntu 镜像：${UBUNTU_MIRROR}" >&2
      exit 1
      ;;
  esac
  echo "==> 备份并更换 Ubuntu 软件源为 ${UBUNTU_MIRROR}"
  sudo cp /etc/apt/sources.list "/etc/apt/sources.list.bak.$(date +%Y%m%d%H%M%S)"
  sudo sed -i \
    -e "s@http://archive.ubuntu.com@${UBUNTU_URL}@g" \
    -e "s@http://security.ubuntu.com@${UBUNTU_URL}@g" \
    -e "s@https://archive.ubuntu.com@${UBUNTU_URL}@g" \
    -e "s@https://security.ubuntu.com@${UBUNTU_URL}@g" \
    /etc/apt/sources.list
fi

echo "==> 下载并核对 ROS 签名密钥"
KEY_TMP="$(mktemp)"
trap 'rm -f "${KEY_TMP}"' EXIT
curl -fsSL --retry 3 --retry-delay 2 \
  "https://raw.githubusercontent.com/ros/rosdistro/master/ros.key" \
  -o "${KEY_TMP}"

if gpg --show-keys "${KEY_TMP}" | grep -q '\[expired'; then
  echo "下载到的 ROS 密钥已经过期。不要改用 packages.ros.org/ros.key，那把密钥在 2025-06-01 过期。" >&2
  exit 1
fi
if ! gpg --show-keys "${KEY_TMP}" | grep -q 'C1CF6E31E6BADE8868B172B4F42ED6FBAB17C654'; then
  echo "密钥指纹对不上，已停止安装。" >&2
  exit 1
fi

sudo mkdir -p /usr/share/keyrings
sudo rm -f /usr/share/keyrings/ros-archive-keyring.gpg
gpg --dearmor < "${KEY_TMP}" | sudo tee /usr/share/keyrings/ros-archive-keyring.gpg >/dev/null

echo "==> 写入 ROS 软件源（${MIRROR}）"
sudo tee /etc/apt/sources.list.d/ros-latest.list >/dev/null <<EOF
deb [arch=${ARCH} signed-by=/usr/share/keyrings/ros-archive-keyring.gpg] ${ROS_URL} focal main
EOF

echo "==> 安装 ROS Noetic 和视觉导航软件包"
sudo apt-get update
sudo apt-get install -y \
  ros-noetic-desktop-full \
  ros-noetic-gmapping \
  ros-noetic-turtlebot3 \
  ros-noetic-turtlebot3-simulations \
  ros-noetic-turtlebot3-slam \
  ros-noetic-turtlebot3-navigation \
  ros-noetic-rtabmap-ros \
  ros-noetic-realsense2-camera \
  ros-noetic-realsense2-description \
  ros-noetic-depthimage-to-laserscan \
  ros-noetic-pointcloud-to-laserscan \
  ros-noetic-teb-local-planner \
  ros-noetic-robot-localization \
  ros-noetic-usb-cam \
  ros-noetic-teleop-twist-keyboard \
  ros-noetic-twist-mux \
  ros-noetic-imu-tools

append_once() {
  local file="$1"
  local line="$2"
  touch "${file}"
  if ! grep -Fqx "${line}" "${file}"; then
    printf '\n%s\n' "${line}" >> "${file}"
  fi
}

append_once "${HOME}/.bashrc" "source /opt/ros/noetic/setup.bash"
append_once "${HOME}/.bashrc" "export TURTLEBOT3_MODEL=burger"

echo "==> 初始化 rosdep"
if [[ ! -f /etc/ros/rosdep/sources.list.d/20-default.list ]]; then
  sudo rosdep init || true
fi
if ! rosdep update; then
  cat <<'EOF'

rosdep update 没有成功。国内网络访问 GitHub 时经常这样。
软件包本身已经装好，可以先继续。等需要从源码编译依赖时，再执行：

  sudo pip3 install -U rosdepc
  sudo rosdepc init
  rosdepc update

EOF
fi

echo "==> 创建工作空间 ${WORKSPACE}"
# shellcheck disable=SC1091
source /opt/ros/noetic/setup.bash
mkdir -p "${WORKSPACE}/src"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -d "${REPO_ROOT}/visual_nav_bringup" ]]; then
  rm -rf "${WORKSPACE}/src/visual_nav_bringup"
  cp -a "${REPO_ROOT}/visual_nav_bringup" "${WORKSPACE}/src/visual_nav_bringup"
fi
pushd "${WORKSPACE}" >/dev/null
catkin_make
popd >/dev/null
append_once "${HOME}/.bashrc" "source ${WORKSPACE}/devel/setup.bash"

sudo systemctl enable --now ssh
sudo systemctl enable --now chrony

echo
echo "安装完成。请打开一个新终端，然后运行："
echo "  bash ${REPO_ROOT}/scripts/check-ros-env.sh"
echo "  roscore"
