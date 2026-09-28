# Ubuntu 20.04 视觉导航配置指南

这份指南面向一台新装的 Ubuntu 20.04，目标是把系统配到可以做视觉导航：用深度相机建图，再让底盘按目标点移动。

对应的 ROS 版本是 **ROS 1 Noetic**。它只正式支持 Ubuntu 20.04。下面的安装源在 2026-09-28 仍可下载，软件包最后更新于 2025-05-29，之后不再有安全和缺陷修复。

## 先决定要不要留在 20.04

系统刚装好、里面还没有数据时，可以先重装一个仍在维护期里的组合：

| 系统 | ROS | 官方支持到 |
| --- | --- | --- |
| Ubuntu 20.04 | ROS 1 Noetic | 2025-05，已结束 |
| Ubuntu 22.04 | ROS 2 Humble | 2027-05 |
| Ubuntu 24.04 | ROS 2 Jazzy | 2029-05 |

继续使用这台 20.04 完全可以开工。视觉建图用 RTAB-Map，导航用 `move_base`。若改去 22.04 或 24.04，对应的导航栈是 Nav2，本指南的命令不能直接照搬。

硬件上优先用 **RGB-D 相机**（Intel RealSense D435 / D435i / D455）。单目相机没有真实尺度，不适合作为第一套导航传感器。

## 配完以后数据怎么走

```text
RealSense 彩色图 + 对齐深度
        |
        +--> RTAB-Map：视觉定位，发布 map -> odom，以及二维栅格 /rtabmap/grid_map
        |
        +--> depthimage_to_laserscan：深度图中间一条变成 /scan
                    |
                    v
              move_base
              全局规划 GlobalPlanner
              局部规划 TebLocalPlanner
                    |
                    v
                 /cmd_vel
                    |
                    v
                  底盘驱动
```

坐标系固定成这一条链：

```text
map  ->  odom  ->  base_link  ->  camera_link  ->  相机光学坐标系
```

- `map -> odom` 由 RTAB-Map 发布，用来修正累积误差。
- `odom -> base_link` 由视觉里程计或轮式里程计发布，两边只能有一个发布者。
- `base_link -> camera_link` 是安装位置，用静态 TF 写死。默认相机在底盘中心前方 10 厘米、高 20 厘米，上车后要改成实测值。

## 1. 系统基础

先更新系统，并保证能用 `sudo`：

```bash
sudo apt update
sudo apt upgrade -y
```

在国内时，Ubuntu 官方源往往很慢。可以换成清华源（会先备份原来的 `sources.list`）：

```bash
sudo cp /etc/apt/sources.list /etc/apt/sources.list.bak
sudo sed -i \
  -e 's@http://archive.ubuntu.com@https://mirrors.tuna.tsinghua.edu.cn@g' \
  -e 's@http://security.ubuntu.com@https://mirrors.tuna.tsinghua.edu.cn@g' \
  -e 's@https://archive.ubuntu.com@https://mirrors.tuna.tsinghua.edu.cn@g' \
  -e 's@https://security.ubuntu.com@https://mirrors.tuna.tsinghua.edu.cn@g' \
  /etc/apt/sources.list
sudo apt update
```

阿里云把上面的地址换成 `https://mirrors.aliyun.com`。

看局域网地址用：

```bash
ip -4 addr
hostname -I
```

`127.0.0.1` 只属于这台机器自己。远程连接用网卡上的 `192.168.x.x`、`10.x.x.x` 或 `172.16.x.x`，一般挂在 `enp*`、`eth*` 或 `wlan*` 上。

打开 SSH，方便另一台电脑登录：

```bash
sudo apt install -y openssh-server
sudo systemctl enable --now ssh
```

另一台电脑上执行 `ssh 用户名@局域网IP`。

多台机器一起跑 ROS 时，时钟要一致：

```bash
sudo apt install -y chrony
sudo systemctl enable --now chrony
```

磁盘至少留 20 GB。内存 8 GB 更合适，4 GB 能装，开 Gazebo 会很吃力。有 NVIDIA 独显并且准备以后跑视觉算法时，再执行 `ubuntu-drivers devices` 看推荐驱动，然后 `sudo ubuntu-drivers autoinstall`。核显和虚拟机先不要装 NVIDIA 驱动。

## 2. 安装 ROS Noetic

把本仓库放到这台电脑上之后，用普通用户执行：

```bash
bash scripts/setup-ubuntu2004-ros-noetic.sh
```

默认使用清华 ROS 镜像。中科大镜像加 `--mirror ustc`，官方源加 `--mirror official`。希望脚本顺手更换 Ubuntu 源时加 `--ubuntu-mirror tuna` 或 `--ubuntu-mirror aliyun`。

脚本会做这些事：

1. 安装编译工具、SSH、chrony、`v4l-utils`。
2. 打开 `universe`、`restricted`、`multiverse`。
3. 确认系统语言环境是 UTF-8。
4. 安装 2030-06-01 才过期的 ROS 签名密钥。`http://packages.ros.org/ros.key` 那把已经在 2025-06-01 过期，不要用。
5. 安装 `ros-noetic-desktop-full`，以及建图、导航、RealSense、TurtleBot3 仿真需要的包。
6. 初始化 `rosdep`，创建 `~/catkin_ws`，并把 `visual_nav_bringup` 放进工作空间。
7. 在 `~/.bashrc` 里加入 Noetic 和工作空间的环境。

装完打开一个新终端。密钥要从 GitHub 下载。这台机器访问不了 GitHub 时，在能打开的电脑上下载 <https://raw.githubusercontent.com/ros/rosdistro/master/ros.key>，拷到本机后再手动完成下面的软件源步骤。

### 想自己逐步执行时

```bash
sudo apt install -y curl gnupg lsb-release ca-certificates software-properties-common
sudo add-apt-repository -y universe
sudo add-apt-repository -y restricted
sudo add-apt-repository -y multiverse

curl -fsSL https://raw.githubusercontent.com/ros/rosdistro/master/ros.key -o /tmp/ros.key
gpg --show-keys /tmp/ros.key
# 指纹必须是 C1CF6E31E6BADE8868B172B4F42ED6FBAB17C654，并且不能显示 expired

sudo mkdir -p /usr/share/keyrings
gpg --dearmor < /tmp/ros.key | sudo tee /usr/share/keyrings/ros-archive-keyring.gpg >/dev/null

echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/ros-archive-keyring.gpg] https://mirrors.tuna.tsinghua.edu.cn/ros/ubuntu/ focal main" \
  | sudo tee /etc/apt/sources.list.d/ros-latest.list

sudo apt update
sudo apt install -y ros-noetic-desktop-full
```

然后安装视觉导航这一组：

```bash
sudo apt install -y \
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
  ros-noetic-imu-tools \
  python3-rosdep python3-rosinstall python3-rosinstall-generator \
  python3-wstool python3-catkin-tools build-essential git
```

写入环境并创建工作空间：

```bash
echo "source /opt/ros/noetic/setup.bash" >> ~/.bashrc
echo "export TURTLEBOT3_MODEL=burger" >> ~/.bashrc
source /opt/ros/noetic/setup.bash

sudo rosdep init
rosdep update

mkdir -p ~/catkin_ws/src
cp -a visual_nav_bringup ~/catkin_ws/src/
cd ~/catkin_ws
catkin_make
echo "source ~/catkin_ws/devel/setup.bash" >> ~/.bashrc
source ~/.bashrc
```

`rosdep update` 访问 GitHub 失败时，软件包已经在，可以先往下做。以后要从源码编译再安装国内可用的 `rosdepc`：

```bash
sudo pip3 install -U rosdepc
sudo rosdepc init
rosdepc update
```

## 3. 检查安装

新终端里运行：

```bash
bash scripts/check-ros-env.sh
echo "$ROS_DISTRO"
```

第二行应输出 `noetic`。

最小通信测试，开三个终端：

```bash
roscore
```

```bash
rosrun turtlesim turtlesim_node
```

```bash
rosrun turtlesim turtle_teleop_key
```

焦点放在第三个终端，方向键能让乌龟移动，说明 ROS 主节点、话题和键盘节点都通了。结束时在每个终端按 `Ctrl+C`。

## 4. 先在仿真里跑通导航

这一步用激光雷达仿真，目的是熟悉地图、初始位姿和目标点。它还不是视觉导航。当前软件源里没有 `cartographer_ros`，仿真 SLAM 用 gmapping。

三个终端都要已经 `source` 过 Noetic。`TURTLEBOT3_MODEL` 已由安装脚本写成 `burger`。

终端 A，启动仿真世界：

```bash
roslaunch turtlebot3_gazebo turtlebot3_world.launch
```

终端 B，建图：

```bash
roslaunch turtlebot3_slam turtlebot3_slam.launch slam_methods:=gmapping
```

终端 C，键盘遥控，让机器人把房间走一遍：

```bash
roslaunch turtlebot3_teleop turtlebot3_teleop_key.launch
```

地图覆盖了要走的区域后，保存：

```bash
mkdir -p ~/maps
rosrun map_server map_saver -f ~/maps/room
```

关掉终端 B 的建图（不要关 Gazebo），再开导航：

```bash
roslaunch turtlebot3_navigation turtlebot3_navigation.launch map_file:=$HOME/maps/room.yaml
```

在 RViz 里：

1. 用 **2D Pose Estimate** 在机器人实际位置点一下，给出初始位姿。
2. 用 **2D Nav Goal** 点一个空地上的目标。
3. 机器人应自己规划并开过去。

Gazebo 窗口是黑的时，多半是显卡驱动或虚拟机没有 3D 加速。可以临时用软件渲染确认程序本身能起来，速度会很慢：

```bash
export LIBGL_ALWAYS_SOFTWARE=1
roslaunch turtlebot3_gazebo turtlebot3_empty_world.launch
```

## 5. 接上深度相机

插入 RealSense 后看设备：

```bash
lsusb | grep -i intel
ls /dev/video*
```

普通 USB 相机可以用 `usb_cam`，但没有深度，只能当图像源，不能按本指南直接导航。

启动相机（这一步只为了确认画面，后面的建图启动文件会自己打开相机）：

```bash
roslaunch realsense2_camera rs_camera.launch align_depth:=true enable_sync:=true
```

另一个终端：

```bash
rostopic hz /camera/color/image_raw
rostopic hz /camera/aligned_depth_to_color/image_raw
```

两个话题都有大约 30 Hz 的输出就可以关掉。D435i 才有 IMU。D435 没有 IMU，不要打开 `enable_gyro`。

RealSense 的出厂内参可以直接用。自制双目或单目 USB 相机需要标定。打印棋盘格后，把 `--size` 换成内角点个数，`--square` 换成格子边长（米）：

```bash
rosrun camera_calibration cameracalibrator.py \
  --size 8x6 --square 0.024 \
  image:=/usb_cam/image_raw camera:=/usb_cam
```

样本够了以后点 SAVE，再把结果写进相机驱动读取的 yaml。

不要使用 `roslaunch realsense2_camera rs_rtabmap.launch`。这份 Noetic 包里的该文件仍去找 `rtabmap_ros/launch/rtabmap.launch`，而 0.21 版的启动文件在 `rtabmap_launch` 包里。它还默认同时要一台 T265 和一台 D400。

## 6. 视觉建图

测量相机相对底盘中心的位置，改 `visual_nav_bringup/launch/realsense_rtabmap.launch` 里的 `camera_x`、`camera_y`、`camera_z`，单位是米。改完在工作空间里重新 `catkin_make`，或确认 `rospack find visual_nav_bringup` 指向的就是你改过的那份源码。

没有轮式里程计时，直接：

```bash
roslaunch visual_nav_bringup realsense_rtabmap.launch
```

RTAB-Map 会发布 `odom -> base_link`。拿着机器人或遥控它缓慢走过环境。RViz 里应出现彩色点云和一张二维栅格。

底盘已经发布 `/odom` 以及 `odom -> base_link` 时，关掉视觉里程计，避免两套 TF 抢同一个坐标系：

```bash
roslaunch visual_nav_bringup realsense_rtabmap.launch visual_odometry:=false
```

D435i 可以附带 IMU：

```bash
roslaunch visual_nav_bringup realsense_rtabmap.launch \
  enable_imu:=true unite_imu_method:=linear_interpolation
```

建图时看这几项：

```bash
rostopic echo /rtabmap/grid_map -n 1
rosrun tf tf_echo map base_link
rostopic hz /scan
```

`/scan` 来自深度图中间 10 行，最远 4 米，最近 0.3 米。相机太朝下会把地面当成墙，把相机抬平，或把 `launch/depth_to_scan.launch` 里的 `scan_height` 调小。

地图数据库在 `~/.ros/rtabmap.db`。重新建图时保持 `delete_db:=true`（默认就是）。这张库要留下来做定位时，下次改成：

```bash
roslaunch visual_nav_bringup realsense_rtabmap.launch localization:=true delete_db:=false
```

地面约束写在启动参数里：只优化平面运动（`Reg/Force3DoF`），用深度生成 5 厘米的二维栅格，4 米以外的深度不参与地图。参数说明在 `visual_nav_bringup/config/rtabmap_ground.ini`。

## 7. 把地图交给导航

建图正常、`/scan` 有数据、TF 链不断之后，同一条启动命令加上导航：

```bash
roslaunch visual_nav_bringup realsense_rtabmap.launch navigation:=true
```

这会把 `/rtabmap/grid_map` 转发到 `/map`，并启动 `move_base`。底盘必须已经订阅 `/cmd_vel`。

在 RViz 里添加：

- `Map`，话题 `/map`
- `LaserScan`，话题 `/scan`
- `Path`，话题 `/move_base/NavfnROS/plan` 或 `/move_base/GlobalPlanner/plan`
- `Pose`，用 **2D Nav Goal**

上车前用尺子改这两个文件，并保持两者描述的是同一台车：

- `visual_nav_bringup/config/navigation/costmap_common.yaml` 里的 `footprint`
- `visual_nav_bringup/config/navigation/teb_local_planner.yaml` 里的 `radius`、`max_vel_x`、`max_vel_theta`

速度先保持 0.3 米/秒。机器人冲过目标或贴着障碍走，就加大 `inflation_radius` 和 `min_obstacle_dist`，并降低 `max_vel_x`。

全局代价地图的坐标系是 `map`，局部代价地图的坐标系是 `odom`。局部地图是一块跟着机器人走的 4 米窗口，用来躲开新出现的障碍。

有轮式编码器和 IMU 时，可以用 `robot_localization` 的 EKF 把它们融合成更稳的 `/odom`。融合节点和视觉里程计仍然只能有一个向 `odom -> base_link` 发布 TF。

## 8. 远程查看

SSH 负责登录终端。RViz 要在另一台电脑上看时，那台电脑也安装 ROS Noetic，并且两台机器在同一个局域网。

机器人上，把地址换成 `hostname -I` 的结果，写进 `~/.bashrc`：

```bash
export ROS_MASTER_URI=http://192.168.1.20:11311
export ROS_IP=192.168.1.20
```

笔记本上：

```bash
export ROS_MASTER_URI=http://192.168.1.20:11311
export ROS_IP=192.168.1.30
```

模板在 `config/ros_network.sh.example`。不要同时设置 `ROS_HOSTNAME`，除非这个主机名在两台机器上都能解析。改完环境变量后重新打开终端，再启动 `roslaunch`。

笔记本上执行 `rostopic list` 能看到机器人的话题后，再开 `rviz`。

如果开了 `ufw`，ROS 1 的随机端口会被挡住。实验机器可以先 `sudo ufw disable`。需要防火墙时，只放行实验室网段，而不是在公网暴露 11311。

## 9. 验收清单

- `bash scripts/check-ros-env.sh` 没有缺失项。
- `turtlesim` 能用键盘移动。
- Gazebo 里的 TurtleBot3 能建图，并按 RViz 目标点导航。
- RealSense 的彩色和深度话题都有频率。
- `rosrun tf tf_echo map base_link` 持续有输出，没有 “frame does not exist”。
- `/scan` 在对着障碍物时距离会变小，对着空地时距离接近量程。
- `~/.ros/rtabmap.db` 在建图后体积增大。
- 底盘对 `/cmd_vel` 有反应，RViz 里给出的目标点能让车动起来并在障碍前停下。

## 10. 常见问题

**`sudo apt update` 报 EXPKEYSIG 或没有公钥。**  
正在使用过期的 `packages.ros.org/ros.key`。删掉 `/etc/apt/sources.list.d/ros-latest.list` 和旧密钥后，改用第 2 节里从 GitHub 下载的那把密钥。

**`rosdep update` 超时。**  
安装阶段可以忽略。需要时改用 `rosdepc`。

**`ifconfig` 不存在。**  
用 `ip addr`。想要原来的命令再执行 `sudo apt install net-tools`。

**RViz 报 Timed out waiting for transform。**  
某一段 TF 没人发布。按 `map -> odom -> base_link -> camera_link` 逐段用 `rosrun tf tf_echo` 查。轮式里程计和 `visual_odometry:=true` 同时打开时，两段 `odom -> base_link` 会打架，只能留一个。

**栅格里全是障碍，车不敢动。**  
相机看到了地面或机身。抬高相机、减小 `scan_height`，或把 `min_obstacle_height` 提到 0.10 以上。

**定位启动后地图是空的。**  
`localization:=true` 时必须 `delete_db:=false`，并且 `~/.ros/rtabmap.db` 是上一次建好的库。

**仿真 SLAM 提示找不到 cartographer。**  
使用 `slam_methods:=gmapping`。这个快照源里没有 Cartographer 的安装包。
