#!/usr/bin/env bash
# 克隆 Marathongo，编译极简巡线工作空间，并把 glio_mapping 复制到独立工作空间后编译。
# 用法：bash scripts/setup-marathongo.sh
# 需要已经安装 ROS Noetic。不编译 marathontracking 和 vision_part。
set -euo pipefail

MARATHON_DIR="${HOME}/marathongo"
GLIO_WS="${HOME}/glio_ws"
REPO_URL="https://github.com/landitbot/marathongo.git"

if [[ "${EUID}" -eq 0 ]]; then
  echo "请用普通用户运行。需要管理员权限时，脚本会自己调用 sudo。" >&2
  exit 1
fi

if [[ ! -f /opt/ros/noetic/setup.bash ]]; then
  echo "还没有 ROS Noetic。请先运行 scripts/setup-ubuntu2004-ros-noetic.sh" >&2
  exit 1
fi

source_noetic() {
  set +u
  # shellcheck disable=SC1091
  source /opt/ros/noetic/setup.bash
  set -u
}

echo "==> 获取比赛仓库 ${MARATHON_DIR}"
if [[ -d "${MARATHON_DIR}/.git" ]]; then
  if ! git -C "${MARATHON_DIR}" pull --ff-only; then
    echo "git pull 没有完成。已保留 ${MARATHON_DIR} 里的现有文件，继续使用这份代码。"
  fi
elif [[ -e "${MARATHON_DIR}" ]]; then
  echo "${MARATHON_DIR} 已存在，但不是 git 仓库。请移走该目录后再运行，以免覆盖已有文件。" >&2
  exit 1
else
  git clone "${REPO_URL}" "${MARATHON_DIR}"
fi

if [[ ! -d "${MARATHON_DIR}/tangent_arc_navigation" || ! -d "${MARATHON_DIR}/glio_mapping" ]]; then
  echo "克隆结果不完整，缺少 tangent_arc_navigation 或 glio_mapping。" >&2
  exit 1
fi

echo "==> 编译 tangent_arc_navigation"
source_noetic
(
  cd "${MARATHON_DIR}/tangent_arc_navigation"
  bash setup_workspace_env.sh
  set +u
  # shellcheck disable=SC1091
  source /opt/ros/noetic/setup.bash
  catkin_make
  set -u
)

echo "==> 把 glio_mapping 复制到 ${GLIO_WS}"
mkdir -p "${GLIO_WS}/src"
if [[ -d "${GLIO_WS}/src/glio_mapping" ]]; then
  echo "工作空间里已有 glio_mapping，保留现有文件。"
else
  cp -a "${MARATHON_DIR}/glio_mapping" "${GLIO_WS}/src/glio_mapping"
fi

echo "==> 安装 glio_mapping 的系统依赖并编译"
sudo apt-get update
sudo apt-get install -y \
  libgoogle-glog-dev \
  libgflags-dev \
  gdal-bin \
  libgdal-dev \
  libpcap-dev \
  libpcl-dev \
  libeigen3-dev \
  ros-noetic-moveit-msgs \
  ros-noetic-serial \
  ros-noetic-pcl-ros \
  ros-noetic-tf2-ros

# glio_mapping 的 CMakeLists 把 livox_ros_driver 写成了必选依赖，即使用速腾雷达也要先编过这个包。
if [[ ! -f /usr/local/lib/liblivox_sdk_static.a && ! -f /usr/local/lib/liblivox_sdk.so ]]; then
  echo "==> 编译 Livox-SDK"
  LIVOX_SDK_DIR="${HOME}/Livox-SDK"
  if [[ ! -d "${LIVOX_SDK_DIR}/.git" ]]; then
    git clone https://github.com/Livox-SDK/Livox-SDK.git "${LIVOX_SDK_DIR}"
  fi
  cmake -S "${LIVOX_SDK_DIR}" -B "${LIVOX_SDK_DIR}/build"
  cmake --build "${LIVOX_SDK_DIR}/build" -j"$(nproc)"
  sudo cmake --install "${LIVOX_SDK_DIR}/build"
fi

if [[ ! -d "${GLIO_WS}/src/livox_ros_driver/.git" ]]; then
  git clone https://github.com/Livox-SDK/livox_ros_driver.git "${GLIO_WS}/src/livox_ros_driver"
fi

(
  cd "${GLIO_WS}"
  set +u
  # shellcheck disable=SC1091
  source /opt/ros/noetic/setup.bash
  catkin_make
  set -u
)

append_once() {
  local file="$1"
  local line="$2"
  touch "${file}"
  if ! grep -Fqx "${line}" "${file}"; then
    printf '\n%s\n' "${line}" >> "${file}"
  fi
}

append_once "${HOME}/.bashrc" "source ${MARATHON_DIR}/tangent_arc_navigation/devel/setup.bash --extend"
append_once "${HOME}/.bashrc" "source ${GLIO_WS}/devel/setup.bash --extend"

echo
echo "比赛仓库已配置。新终端会通过 ~/.bashrc 依次加载："
echo "  /opt/ros/noetic"
echo "  ${HOME}/visual_ws"
echo "  ${MARATHON_DIR}/tangent_arc_navigation  (--extend)"
echo "  ${GLIO_WS}  (--extend)"
echo "marathontracking 和 vision_part 还没有编译。要改巡线代码，直接编辑："
echo "  ${MARATHON_DIR}/tangent_arc_navigation"
echo "  ${MARATHON_DIR}/marathontracking"
echo "glio_mapping 的原文在 ${MARATHON_DIR}/glio_mapping，修改副本在 ${GLIO_WS}/src/glio_mapping。"
