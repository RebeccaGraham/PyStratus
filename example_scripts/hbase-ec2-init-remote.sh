#!/bin/bash -x

# Licensed to the Apache Software Foundation (ASF) under one or more
# contributor license agreements.  See the NOTICE file distributed with
# this work for additional information regarding copyright ownership.
# The ASF licenses this file to You under the Apache License, Version 2.0
# (the "License"); you may not use this file except in compliance with
# the License.  You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

################################################################################
# Script that is run on each EC2 instance on boot. It is passed in the EC2 user
# data, so should not exceed 16K in size after gzip compression.
#
# This script is executed by /etc/init.d/ec2-run-user-data, and output is
# logged to /var/log/messages.
#
# This script will set up a Hadoop/HBase cluster.  Zookeeper is
# installed and launched on the namenode/jobtracker/master node.  This is a 
# configuration that is suitable for small clusters or for testing, but not for
# most production environments.
#
# Since the regionservers all need the private dns name of the zookeeper
# machine, that machine must be started before the regionservers.  By default, 
# a zookeeper is running on the same machine as the master, so you will need to
# first launch the master node, then the slaves:
#
#   stratus exec my-cluster launch-master
#   stratus exec my-cluster launch-slaves 10
#
# 
################################################################################

################################################################################
# Initialize variables
################################################################################

# Substitute environment variables passed by the client
export %ENV%

echo "export %ENV%" >> ~root/.bash_profile
#for some reason, the .bash_profile in some distros does not source .bashrc
cat >> ~root/.bash_profile <<EOF
if [ -f ~/.bashrc ]; then
   source ~/.bashrc
fi
EOF
echo "export %ENV%" >> ~root/.bashrc

# up ulimits if necessary
if [ `ulimit -n` -lt 128000 ]; then 
	ulimit -n 128000
fi

HADOOP_VERSION=${HADOOP_VERSION:-0.20.2-cdh3u0}
HADOOP_HOME=/usr/local/hadoop-$HADOOP_VERSION
HADOOP_CONF_DIR=$HADOOP_HOME/conf

HBASE_VERSION=${HBASE_VERSION:-0.90.1-cdh3u0}
HBASE_HOME=/usr/local/hbase-$HBASE_VERSION
HBASE_CONF_DIR=$HBASE_HOME/conf

ZK_VERSION=${ZK_VERSION:-3.3.3-cdh3u0}
ZK_HOME=/usr/local/zookeeper-$ZK_VERSION
ZK_CONF_DIR=$ZK_HOME/conf

PIG_VERSION=${PIG_VERSION:-pig-0.8.0-cdh3u0}
PIG_HOME=/usr/local/pig-$PIG_VERSION
PIG_CONF_DIR=$PIG_HOME/conf

#HDFS settings to support HBase
DFS_DATANODE_HANDLER_COUNT=10
DFS_DATANODE_MAX_XCIEVERS=10000
#end of HDFS settings

SELF_HOST=`wget -q -O - http://169.254.169.254/latest/meta-data/public-hostname`
for role in $(echo "$ROLES" | tr "," "\n"); do
  case $role in
  nn)
    NN_HOST=$SELF_HOST
    # By default the HBase master and Zookeeper run on the Namenode host
    # Zookeeper uses the private IP address of the namenode
    ZOOKEEPER_QUORUM=`echo $HOSTNAME`
    ;;
  jt)
    JT_HOST=$SELF_HOST
    ;;
  esac
done

# Set up the macro that we will use to execute commands as "hadoop"
if which dpkg &> /dev/null; then
  AS_HADOOP="su -s /bin/bash - hadoop -c"
elif which rpm &> /dev/null; then
  AS_HADOOP="/sbin/runuser -s /bin/bash - hadoop -c"
fi

function register_auto_shutdown() {
  if [ ! -z "$AUTO_SHUTDOWN" ]; then
    shutdown -h +$AUTO_SHUTDOWN >/dev/null &
  fi
}

# Install a list of packages on debian or redhat as appropriate
function install_packages() {
  if which dpkg &> /dev/null; then
    apt-get update
    apt-get -y install $@
  elif which rpm &> /dev/null; then
    yum install -y $@
  else
    echo "No package manager found."
  fi
}

# Install any user packages specified in the USER_PACKAGES environment variable
function install_user_packages() {
  if [ ! -z "$USER_PACKAGES" ]; then
    install_packages $USER_PACKAGES
  fi
}

function install_yourkit() {
    mkdir /mnt/yjp
    YOURKIT_URL="http://www.yourkit.com/download/yjp-9.0.7-linux.tar.bz2"
    curl="curl --retry 3 --silent --show-error --fail"
    $curl -O $YOURKIT_URL
    yourkit_tar_file=`basename $YOURKIT_URL`
    tar xjf $yourkit_tar_file -C /mnt/yjp
    rm -f $yourkit_tar_file
    chown -R hadoop /mnt/yjp
	chgrp -R hadoop /mnt/yjp
}

function install_hadoop() {
  #The EBS volumes are already set up with hadoop:hadoop equal to 500:500
  if which dpkg &> /dev/null; then
    addgroup hadoop --gid 500
    adduser --disabled-login --ingroup hadoop --gecos GECOS --uid 500 hadoop
  else
     groupadd hadoop -g 500
     useradd hadoop -u 500 -g 500
  fi

  
  hadoop_tar_url=http://archive.cloudera.com/cdh/3/hadoop-$HADOOP_VERSION.tar.gz
  hadoop_tar_file=`basename $hadoop_tar_url`

  curl="curl --retry 3 --silent --show-error --fail"
  $curl -O $hadoop_tar_url

  if [ ! -e $hadoop_tar_file ]; then
    echo "Failed to download $hadoop_tar_url. Aborting."
    exit 1
  fi

  tar zxf $hadoop_tar_file -C /usr/local
  cp $HADOOP_HOME/contrib/fairscheduler/hadoop-*-fairscheduler.jar $HADOOP_HOME/lib
  rm -f $hadoop_tar_file $hadoop_tar_md5_file

  echo "export HADOOP_HOME=$HADOOP_HOME" >> ~root/.bashrc
  echo 'export PATH=$JAVA_HOME/bin:$HADOOP_HOME/bin:$PATH' >> ~root/.bashrc
  
  #set up the native compression libraries
  if [ `arch` == 'x86_64' ]; then
    cp $HADOOP_HOME/lib/native/Linux-amd64-64/libhadoop.* /usr/lib/
  else
    cp $HADOOP_HOME/lib/native/ Linux-i386-32/libhadoop.* /usr/lib/
  fi
  ldconfig -n /usr/lib/
}

function install_hbase() {
  hbase_tar_url=http://archive.cloudera.com/cdh/3/hbase-$HBASE_VERSION.tar.gz
  hbase_tar_file=`basename $hbase_tar_url`

  curl="curl --retry 3 --silent --show-error --fail"
  $curl -O $hbase_tar_url

  if [ ! -e $hbase_tar_file ]; then
    echo "Failed to download $hbase_tar_url. Aborting."
    exit 1
  fi

  tar zxf $hbase_tar_file -C /usr/local
  rm -f $hbase_tar_file $hbase_tar_md5_file

  echo "export HBASE_HOME=$HBASE_HOME" >> ~root/.bashrc
  echo 'export PATH=$JAVA_HOME/bin:$HBASE_HOME/bin:$PATH' >> ~root/.bashrc
}

function install_zookeeper() {
  zk_tar_url=http://archive.cloudera.com/cdh/3/zookeeper-$ZK_VERSION.tar.gz
  zk_tar_file=`basename $zk_tar_url`

  curl="curl --retry 3 --silent --show-error --fail"
  $curl -O $zk_tar_url

  if [ ! -e $zk_tar_file ]; then
    echo "Failed to download $zk_tar_url. Aborting."
    exit 1
  fi

  tar zxf $zk_tar_file -C /usr/local
  rm -f $zk_tar_file $zk_tar_md5_file

  echo "export ZOOKEEPER_HOME=$ZK_HOME" >> ~root/.bashrc
  echo 'export PATH=$JAVA_HOME/bin:$ZK_HOME/bin:$PATH' >> ~root/.bashrc
}

function install_pig()
{
  pig_tar_url=http://archive.cloudera.com/cdh/3/$PIG_VERSION.tar.gz
  pig_tar_file=`basename $pig_tar_url`

  curl="curl --retry 3 --silent --show-error --fail"
  for i in `seq 1 3`;
  do
    $curl -O $pig_tar_url
  done

  if [ ! -e $pig_tar_file ]; then
    echo "Failed to download $pig_tar_url. Pig will not be installed."
  else
    tar zxf $pig_tar_file -C /usr/local
    rm -f $pig_tar_file
 
    if [ ! -e $HADOOP_CONF_DIR ]; then
      echo "Hadoop must be installed.  Aborting."
      exit 1
    fi

    cp $HADOOP_CONF_DIR/*.xml $PIG_CONF_DIR/

    echo "export PIG_HOME=$PIG_HOME" >> ~root/.bashrc
    echo 'export PATH=$JAVA_HOME/bin:$PIG_HOME/bin:$PATH' >> ~root/.bashrc
 fi
}

function prep_disk() {
  mount=$1
  device=$2
  automount=${3:-false}

  echo "warning: ERASING CONTENTS OF $device"
  mkfs.xfs -f $device
  if [ ! -e $mount ]; then
    mkdir $mount
  fi
  mount -o defaults,noatime $device $mount
  if $automount ; then
    echo "$device $mount xfs defaults,noatime 0 0" >> /etc/fstab
  fi
}

function wait_for_mount {
  mount=$1
  device=$2

  mkdir $mount

  i=1
  echo "Attempting to mount $device"
  while true ; do
    sleep 10
    echo -n "$i "
    i=$[$i+1]
    mount -o defaults,noatime $device $mount || continue
    echo " Mounted."
    break;
  done
}

function make_hadoop_dirs {
  for mount in "$@"; do
    if [ ! -e $mount/hadoop ]; then
      mkdir -p $mount/hadoop
      chown hadoop:hadoop $mount/hadoop
    fi
  done
}

# Configure Hadoop by setting up disks and site file
function configure_hadoop() {
    #set up hadoop's env. to have the same path and vars as root
    #this ensures that commands work correctly when the user su's to hadoop
    cp ~/.bash_profile /home/hadoop/
    cp ~/.bashrc /home/hadoop/
    chown hadoop /home/hadoop/.bash*
    chgrp hadoop /home/hadoop/.bash*

  install_packages xfsprogs # needed for XFS

  INSTANCE_TYPE=`wget -q -O - http://169.254.169.254/latest/meta-data/instance-type`

  if [ -n "$EBS_MAPPINGS" ]; then
    # EBS_MAPPINGS is like "nn,/ebs1,/dev/sdj;dn,/ebs2,/dev/sdk"
    # EBS_MAPPINGS is like "ROLE,MOUNT_POINT,DEVICE;ROLE,MOUNT_POINT,DEVICE"
    DFS_NAME_DIR=''
    FS_CHECKPOINT_DIR=''
    DFS_DATA_DIR=''
    for mapping in $(echo "$EBS_MAPPINGS" | tr ";" "\n"); do
      role=`echo $mapping | cut -d, -f1`
      mount=`echo $mapping | cut -d, -f2`
      device=`echo $mapping | cut -d, -f3`
      wait_for_mount $mount $device
      DFS_NAME_DIR=${DFS_NAME_DIR},"$mount/hadoop/hdfs/name"
      FS_CHECKPOINT_DIR=${FS_CHECKPOINT_DIR},"$mount/hadoop/hdfs/secondary"
      DFS_DATA_DIR=${DFS_DATA_DIR},"$mount/hadoop/hdfs/data"
      FIRST_MOUNT=${FIRST_MOUNT-$mount}
      make_hadoop_dirs $mount
    done
    # Remove leading commas
    DFS_NAME_DIR=${DFS_NAME_DIR#?}
    FS_CHECKPOINT_DIR=${FS_CHECKPOINT_DIR#?}
    DFS_DATA_DIR=${DFS_DATA_DIR#?}

    DFS_REPLICATION=3 # EBS is internally replicated, but we also use HDFS replication for safety
  else
    case $INSTANCE_TYPE in
    m2.2xlarge)
      DFS_NAME_DIR=/mnt/hadoop/hdfs/name
      FS_CHECKPOINT_DIR=/mnt/hadoop/hdfs/secondary
      DFS_DATA_DIR=/mnt/hadoop/hdfs/data
      ;;
    m1.xlarge|c1.xlarge)
      DFS_NAME_DIR=/mnt/hadoop/hdfs/name,/mnt2/hadoop/hdfs/name
      FS_CHECKPOINT_DIR=/mnt/hadoop/hdfs/secondary,/mnt2/hadoop/hdfs/secondary
      DFS_DATA_DIR=/mnt/hadoop/hdfs/data,/mnt2/hadoop/hdfs/data,/mnt3/hadoop/hdfs/data,/mnt4/hadoop/hdfs/data
      ;;
    m1.large)
      DFS_NAME_DIR=/mnt/hadoop/hdfs/name,/mnt2/hadoop/hdfs/name
      FS_CHECKPOINT_DIR=/mnt/hadoop/hdfs/secondary,/mnt2/hadoop/hdfs/secondary
      DFS_DATA_DIR=/mnt/hadoop/hdfs/data,/mnt2/hadoop/hdfs/data
      ;;
    *)
      # "m1.small" or "c1.medium"
      DFS_NAME_DIR=/mnt/hadoop/hdfs/name
      FS_CHECKPOINT_DIR=/mnt/hadoop/hdfs/secondary
      DFS_DATA_DIR=/mnt/hadoop/hdfs/data
      ;;
    esac
    FIRST_MOUNT=/mnt
    DFS_REPLICATION=3
  fi

  case $INSTANCE_TYPE in
  m2.2xlarge)
    MAPRED_LOCAL_DIR=/mnt/hadoop/mapred/local
    MAX_MAP_TASKS=5
    MAX_REDUCE_TASKS=3
    CHILD_OPTS=-Xmx2000m
    CHILD_ULIMIT=4000000
    IO_SORT_FACTOR=25
    IO_SORT_MB=250
    ;;
  m1.xlarge|c1.xlarge)
    prep_disk /mnt2 /dev/sdc true &
    disk2_pid=$!
    prep_disk /mnt3 /dev/sdd true &
    disk3_pid=$!
    prep_disk /mnt4 /dev/sde true &
    disk4_pid=$!
    wait $disk2_pid $disk3_pid $disk4_pid
    MAPRED_LOCAL_DIR=/mnt/hadoop/mapred/local,/mnt2/hadoop/mapred/local,/mnt3/hadoop/mapred/local,/mnt4/hadoop/mapred/local
    MAX_MAP_TASKS=4
    MAX_REDUCE_TASKS=2
    CHILD_OPTS=-Xmx2000m
    CHILD_ULIMIT=4000000
    IO_SORT_FACTOR=20
    IO_SORT_MB=200
    ;;
  m1.large)
    prep_disk /mnt2 /dev/sdc true
    MAPRED_LOCAL_DIR=/mnt/hadoop/mapred/local,/mnt2/hadoop/mapred/local
    MAX_MAP_TASKS=2
    MAX_REDUCE_TASKS=1
    CHILD_OPTS=-Xmx2000m
    CHILD_ULIMIT=4000000
    IO_SORT_FACTOR=10
    IO_SORT_MB=100
    ;;
  c1.medium)
    MAPRED_LOCAL_DIR=/mnt/hadoop/mapred/local
    MAX_MAP_TASKS=4
    MAX_REDUCE_TASKS=2
    CHILD_OPTS=-Xmx550m
    CHILD_ULIMIT=1126400
    IO_SORT_FACTOR=10
    IO_SORT_MB=100
    ;;
  *)
    # "m1.small"
    MAPRED_LOCAL_DIR=/mnt/hadoop/mapred/local
    MAX_MAP_TASKS=2
    MAX_REDUCE_TASKS=1
    CHILD_OPTS=-Xmx550m
    CHILD_ULIMIT=1126400
    IO_SORT_FACTOR=10
    IO_SORT_MB=100
    ;;
  esac

  make_hadoop_dirs `ls -d /mnt*`

  # Create tmp directory
  mkdir /mnt/tmp
  chmod a+rwxt /mnt/tmp
  
  mkdir /etc/hadoop
  ln -s $HADOOP_CONF_DIR /etc/hadoop/conf

  ##############################################################################
  # Modify this section to customize your Hadoop cluster.
  ##############################################################################
  cat > $HADOOP_CONF_DIR/hadoop-site.xml <<EOF
<?xml version="1.0"?>
<?xml-stylesheet type="text/xsl" href="configuration.xsl"?>
<configuration>
<property>
  <name>dfs.block.size</name>
  <value>134217728</value>
  <final>true</final>
</property>
<property>
  <name>dfs.data.dir</name>
  <value>$DFS_DATA_DIR</value>
  <final>true</final>
</property>
<property>
  <name>dfs.datanode.du.reserved</name>
  <value>1073741824</value>
  <final>true</final>
</property>
<property>
  <name>dfs.datanode.handler.count</name>
  <value>$DFS_DATANODE_HANDLER_COUNT</value>
  <final>true</final>
</property>
<!--property>
  <name>dfs.hosts</name>
  <value>$HADOOP_CONF_DIR/dfs.hosts</value>
  <final>true</final>
</property-->
<property>
  <name>dfs.hosts.exclude</name>
  <value>$HADOOP_CONF_DIR/exclude</value>
  <final>true</final>
</property>
<property>
  <name>mapred.hosts.exclude</name>
  <value>$HADOOP_CONF_DIR/exclude</value>
  <final>true</final>
</property>
<property>
  <name>dfs.name.dir</name>
  <value>$DFS_NAME_DIR</value>
  <final>true</final>
</property>
<property>
  <name>dfs.namenode.handler.count</name>
  <value>64</value>
  <final>true</final>
</property>
<property>
  <name>dfs.permissions</name>
  <value>true</value>
  <final>true</final>
</property>
<property>
  <name>dfs.replication</name>
  <value>$DFS_REPLICATION</value>
</property>
<property>
 <name>dfs.datanode.max.xcievers</name>
 <value>$DFS_DATANODE_MAX_XCIEVERS</value>
</property>
<property>
  <name>fs.checkpoint.dir</name>
  <value>$FS_CHECKPOINT_DIR</value>
  <final>true</final>
</property>
<property>
  <name>fs.default.name</name>
  <value>hdfs://$NN_HOST:8020/</value>
</property>
<property>
  <name>fs.trash.interval</name>
  <value>1440</value>
  <final>true</final>
</property>
<property>
  <name>hadoop.tmp.dir</name>
  <value>/mnt/tmp/hadoop-\${user.name}</value>
  <final>true</final>
</property>
<property>
  <name>io.file.buffer.size</name>
  <value>65536</value>
</property>
<property>
  <name>io.sort.factor</name>
  <value>$IO_SORT_FACTOR</value>
</property>
<property>
  <name>io.sort.mb</name>
  <value>$IO_SORT_MB</value>
</property>
<property>
  <name>mapred.child.java.opts</name>
  <value>$CHILD_OPTS</value>
</property>
<property>
  <name>mapred.child.ulimit</name>
  <value>$CHILD_ULIMIT</value>
  <final>true</final>
</property>
<property>
  <name>mapred.job.tracker</name>
  <value>$JT_HOST:8021</value>
</property>
<property>
  <name>mapred.job.tracker.handler.count</name>
  <value>64</value>
  <final>true</final>
</property>
<property>
  <name>mapred.local.dir</name>
  <value>$MAPRED_LOCAL_DIR</value>
  <final>true</final>
</property>
<property>
  <name>mapred.map.tasks.speculative.execution</name>
  <value>true</value>
</property>
<property>
  <name>mapred.reduce.parallel.copies</name>
  <value>10</value>
</property>
<property>
  <name>mapred.reduce.tasks</name>
  <value>$CLUSTER_SIZE</value>
</property>
<property>
  <name>mapred.reduce.tasks.speculative.execution</name>
  <value>false</value>
</property>
<property>
  <name>mapred.submit.replication</name>
  <value>10</value>
</property>
<property>
  <name>mapred.system.dir</name>
  <value>/hadoop/system/mapred</value>
</property>
<property>
  <name>mapred.tasktracker.map.tasks.maximum</name>
  <value>$MAX_MAP_TASKS</value>
  <final>true</final>
</property>
<property>
  <name>mapred.tasktracker.reduce.tasks.maximum</name>
  <value>$MAX_REDUCE_TASKS</value>
  <final>true</final>
</property>
<property>
  <name>tasktracker.http.threads</name>
  <value>40</value>
  <final>true</final>
</property>
<property>
  <name>mapred.output.compress</name>
  <value>true</value>
</property>
<property>
  <name>mapred.compress.map.output</name>
  <value>true</value>
</property>
<property>
  <name>mapred.output.compression.type</name>
  <value>BLOCK</value>
</property>
<property>
  <name>hadoop.rpc.socket.factory.class.default</name>
  <value>org.apache.hadoop.net.StandardSocketFactory</value>
  <final>true</final>
</property>
<property>
  <name>hadoop.rpc.socket.factory.class.ClientProtocol</name>
  <value></value>
  <final>true</final>
</property>
<property>
  <name>hadoop.rpc.socket.factory.class.JobSubmissionProtocol</name>
  <value></value>
  <final>true</final>
</property>
<property>
  <name>io.compression.codecs</name>
  <value>org.apache.hadoop.io.compress.DefaultCodec,org.apache.hadoop.io.compress.GzipCodec</value>
</property>
</configuration>
EOF

  # Keep PID files in a non-temporary directory
  sed -i -e "s|# export HADOOP_PID_DIR=.*|export HADOOP_PID_DIR=/var/run/hadoop|" \
    $HADOOP_CONF_DIR/hadoop-env.sh
  mkdir -p /var/run/hadoop
  chown -R hadoop:hadoop /var/run/hadoop

  # Set SSH options within the cluster
  sed -i -e 's|# export HADOOP_SSH_OPTS=.*|export HADOOP_SSH_OPTS="-o StrictHostKeyChecking=no"|' \
    $HADOOP_CONF_DIR/hadoop-env.sh

  # Hadoop logs should be on the /mnt partition
  sed -i -e 's|# export HADOOP_LOG_DIR=.*|export HADOOP_LOG_DIR=/var/log/hadoop/logs|' \
    $HADOOP_CONF_DIR/hadoop-env.sh
    
  rm -rf /var/log/hadoop
  mkdir /mnt/hadoop/logs
  chown hadoop:hadoop /mnt/hadoop/logs
  ln -s /mnt/hadoop/logs /var/log/hadoop
  chown -R hadoop:hadoop /var/log/hadoop

}

# Sets up the HBase configuration
function configure_hbase() {
	
  ##############################################################################
  # Modify this section to customize your HBase cluster.
  ##############################################################################

  HBASE_TMP_DIR=/mnt/hbase
  mkdir $HBASE_TMP_DIR
  chown hadoop:hadoop $HBASE_TMP_DIR
  
  ZOOKEEPER_DATA_DIR=/mnt/hbase/zk
  mkdir $ZOOKEEPER_DATA_DIR
  chown hadoop:hadoop $ZOOKEEPER_DATA_DIR
  
  cat > $HBASE_CONF_DIR/hbase-site.xml <<EOF
<?xml version="1.0"?>
<?xml-stylesheet type="text/xsl" href="configuration.xsl"?>
<configuration>
<property>
 <name>hbase.rootdir</name>
 <value>hdfs://$NN_HOST:8020/hbase</value>
</property>
<property>
 <name>hbase.cluster.distributed</name>
 <value>true</value>
</property>
<property>
 <name>hbase.regionserver.handler.count</name>
 <value>200</value>
</property>
<property>
 <name>hbase.tmp.dir</name>
 <value>$HBASE_TMP_DIR</value>
</property>
<property>
 <name>dfs.replication</name>
 <value>$DFS_REPLICATION</value>
</property>
<!-- zookeeper properties -->
<property>
 <name>hbase.zookeeper.quorum</name>
 <value>$ZOOKEEPER_QUORUM</value>
</property>
<property>
 <name>zookeeper.session.timeout</name>
 <value>60000</value>
</property>
<property>
  <name>hbase.zookeeper.property.dataDir</name>
  <value>$ZOOKEEPER_DATA_DIR</value>
</property>
<property>
  <name>hbase.zookeeper.property.maxClientCnxns</name>
  <value>100</value>
</property>
</configuration>
EOF

  # Override JVM options - use 2G heap for master and 8G for region servers
  cat >> $HBASE_CONF_DIR/hbase-env.sh <<EOF
export HBASE_MASTER_OPTS="-Xms2048m -Xmx2048m -Xmn256m -XX:+UseConcMarkSweepGC -XX:+AggressiveOpts -verbose:gc -XX:+PrintGCDetails -XX:+PrintGCTimeStamps -Xloggc:/mnt/hbase/logs/hbase-master-gc.log"
export HBASE_REGIONSERVER_OPTS="-Xms8g -Xmx12g -Xmn256m -XX:+UseConcMarkSweepGC -XX:+CMSIncrementalMode -XX:ParallelGCThreads=8 -XX:+AggressiveOpts -verbose:gc -XX:+PrintGCDetails -XX:+PrintGCTimeStamps -Xloggc:/mnt/hbase/logs/hbase-regionserver-gc.log"
HBASE_LOG_DIR=${HBASE_TMP_DIR}/logs
EOF

  mkdir /etc/hbase/
  ln -s $HBASE_CONF_DIR /etc/hbase/conf
  ln -s $HBASE_LOG_DIR /var/log/hbase
}

# Sets up small website on cluster.
function setup_web() {

  if which dpkg &> /dev/null; then
    apt-get -y install thttpd
    WWW_BASE=/var/www
  elif which rpm &> /dev/null; then
    yum install -y thttpd
    chkconfig --add thttpd
    WWW_BASE=/var/www/thttpd/html
  fi

  cat > $WWW_BASE/index.html << END
<html>
<head>
<title>Hadoop EC2 Cluster</title>
</head>
<body>
<h1>Hadoop EC2 Cluster</h1>
To browse the cluster you need to have a proxy configured.
Start the proxy with <tt>hadoop-ec2 proxy &lt;cluster_name&gt;</tt>,
and point your browser to
<a href="http://apache-hadoop-ec2.s3.amazonaws.com/proxy.pac">this Proxy
Auto-Configuration (PAC)</a> file.  To manage multiple proxy configurations,
you may wish to use
<a href="https://addons.mozilla.org/en-US/firefox/addon/2464">FoxyProxy</a>.
<ul>
<li><a href="http://$NN_HOST:50070/">NameNode</a>
<li><a href="http://$JT_HOST:50030/">JobTracker</a>
</ul>
</body>
</html>
END

  service thttpd start

}

function start_namenode() {

  # Format HDFS
  [ ! -e $FIRST_MOUNT/hadoop/hdfs ] && $AS_HADOOP "$HADOOP_HOME/bin/hadoop namenode -format"

  $AS_HADOOP "$HADOOP_HOME/bin/hadoop-daemon.sh start namenode"

  #$AS_HADOOP "$HADOOP_HOME/bin/hadoop dfsadmin -safemode wait"
  $AS_HADOOP "$HADOOP_HOME/bin/hadoop fs -mkdir /user"
  # The following is questionable, as it allows a user to delete another user
  # It's needed to allow users to create their own user directories
  $AS_HADOOP "$HADOOP_HOME/bin/hadoop fs -chmod +w /user"

}

function start_daemon() {
  $AS_HADOOP "$HADOOP_HOME/bin/hadoop-daemon.sh start $1"
}

# Launch the Zookeeper and the HBase master node - these must be started
# before adding region servers
function start_master() {
   #Start the zookeeper process first
   $AS_HADOOP "$HBASE_HOME/bin/hbase-daemon.sh start zookeeper"
   #Then start the master
   $AS_HADOOP "$HBASE_HOME/bin/hbase-daemon.sh start master"
}

# Launch a region server
function start_region() {
   $AS_HADOOP "$HBASE_HOME/bin/hbase-daemon.sh start regionserver"
}

register_auto_shutdown
install_user_packages
install_hadoop
install_hbase
install_zookeeper
configure_hadoop
configure_hbase
install_pig

for role in $(echo "$ROLES" | tr "," "\n"); do
  case $role in
  nn)
    setup_web
    start_namenode
    start_master
    ;;
  snn)
    start_daemon secondarynamenode
    ;;
  jt)
    start_daemon jobtracker
    ;;
  dn)
    start_daemon datanode
    start_region
    ;;
  tt)
    start_daemon tasktracker
    if [ ! -z "$INSTALL_PROFILER" ]; then
       install_yourkit
    fi
    ;;
  esac
done

