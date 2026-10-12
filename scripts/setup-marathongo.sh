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

# 每个仓库先克隆官方地址，失败后再使用代理。
git_clone_urls() {
  local repo="$1"
  printf '%s\n' "${repo}" "https://gh-proxy.com/${repo}"
}

clone_repo() {
  local repo="$1"
  local dest="$2"
  shift 2
  local url
  while IFS= read -r url; do
    echo "==> 克隆 ${url}"
    rm -rf "${dest}"
    if git -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=30 \
      clone "$@" "${url}" "${dest}"; then
      return 0
    fi
    echo "克隆没有完成，尝试下一个地址。"
    rm -rf "${dest}"
  done < <(git_clone_urls "${repo}")
  echo "克隆失败：${repo}" >&2
  return 1
}

clone_marathongo() {
  local url
  while IFS= read -r url; do
    echo "==> 克隆比赛代码（不下载 gif 演示图）：${url}"
    rm -rf "${MARATHON_DIR}"
    if git -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=30 -c protocol.version=2 \
      clone --depth 1 --filter=blob:none --no-checkout "${url}" "${MARATHON_DIR}" \
      && (
        cd "${MARATHON_DIR}"
        git sparse-checkout init --cone
        git sparse-checkout set tangent_arc_navigation glio_mapping marathontracking vision_part
        git checkout
      ); then
      return 0
    fi
    echo "这次克隆没有完成，尝试下一个地址。"
    rm -rf "${MARATHON_DIR}"
  done < <(git_clone_urls "${REPO_URL}")
  echo "比赛仓库克隆失败。请检查网络后重新运行本脚本。" >&2
  return 1
}

insert_after_line() {
  local file="$1"
  local anchor="$2"
  local line="$3"
  if grep -Fqx "${line}" "${file}"; then
    return 0
  fi
  if ! grep -Fqx "${anchor}" "${file}"; then
    echo "无法修改 ${file}：找不到插入位置。" >&2
    return 1
  fi
  awk -v anchor="${anchor}" -v extra="${line}" '
    { print }
    $0 == anchor { print extra }
  ' "${file}" > "${file}.tmp"
  mv "${file}.tmp" "${file}"
}

# 上游 CMake 没有声明消息依赖。并行编译时会先去找还没生成的 Pose6D.h。
ensure_glio_message_deps() {
  local root="${GLIO_WS}/src/glio_mapping"
  echo "==> 补上 glio_mapping 的消息生成依赖"
  insert_after_line "${root}/src/CMakeLists.txt" \
    'target_include_directories(${PROJECT_NAME} PRIVATE ${PYTHON_INCLUDE_DIRS})' \
    'add_dependencies(${PROJECT_NAME} ${${PROJECT_NAME}_EXPORTED_TARGETS} ${catkin_EXPORTED_TARGETS})'
  insert_after_line "${root}/thirdparty/CMakeLists.txt" \
    'target_include_directories(thirdparty PRIVATE ${PYTHON_INCLUDE_DIRS})' \
    'add_dependencies(thirdparty ${${PROJECT_NAME}_EXPORTED_TARGETS} ${catkin_EXPORTED_TARGETS})'
  insert_after_line "${root}/app/CMakeLists.txt" \
    'add_executable(${PROJECT_NAME}_node run_mapping_online.cpp)' \
    'add_dependencies(${PROJECT_NAME}_node ${${PROJECT_NAME}_EXPORTED_TARGETS} ${catkin_EXPORTED_TARGETS})'
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
  clone_marathongo
fi

if [[ ! -d "${MARATHON_DIR}/tangent_arc_navigation" || ! -d "${MARATHON_DIR}/glio_mapping" ]]; then
  echo "克隆结果不完整，缺少 tangent_arc_navigation 或 glio_mapping。" >&2
  exit 1
fi

echo "==> 安装巡线和定位需要的系统包"
sudo apt-get update
sudo apt-get install -y \
  build-essential \
  cmake \
  pkg-config \
  python3-pip \
  python3-empy \
  python3-vcstool \
  libeigen3-dev \
  libpcl-dev \
  libtbb-dev \
  libgoogle-glog-dev \
  libgflags-dev \
  libyaml-cpp-dev \
  gdal-bin \
  libgdal-dev \
  libpcap-dev \
  ros-noetic-costmap-converter \
  ros-noetic-pcl-conversions \
  ros-noetic-pcl-ros \
  ros-noetic-tf \
  ros-noetic-tf2-ros \
  ros-noetic-gtsam \
  ros-noetic-moveit-msgs \
  ros-noetic-serial

echo "==> 编译 tangent_arc_navigation"
source_noetic
(
  cd "${MARATHON_DIR}/tangent_arc_navigation"
  # 上游脚本会升级 pip。升级失败时不要中断，上面的 apt 包已经够编译。
  if ! bash setup_workspace_env.sh; then
    echo "setup_workspace_env.sh 没有全部完成。继续编译巡线工作空间。"
  fi
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

ensure_glio_message_deps

echo "==> 准备 Livox 驱动。glio_mapping 把 livox_ros_driver 写成了必选依赖"
if [[ ! -f /usr/local/lib/liblivox_sdk_static.a && ! -f /usr/local/lib/liblivox_sdk.so ]]; then
  echo "==> 编译 Livox-SDK"
  LIVOX_SDK_DIR="${HOME}/Livox-SDK"
  if [[ ! -d "${LIVOX_SDK_DIR}/.git" ]]; then
    clone_repo "https://github.com/Livox-SDK/Livox-SDK.git" "${LIVOX_SDK_DIR}" --depth 1
  fi
  cmake -S "${LIVOX_SDK_DIR}" -B "${LIVOX_SDK_DIR}/build"
  cmake --build "${LIVOX_SDK_DIR}/build" -j"$(nproc)"
  sudo cmake --install "${LIVOX_SDK_DIR}/build"
fi

if [[ ! -d "${GLIO_WS}/src/livox_ros_driver/.git" ]]; then
  clone_repo "https://github.com/Livox-SDK/livox_ros_driver.git" \
    "${GLIO_WS}/src/livox_ros_driver" --depth 1
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
