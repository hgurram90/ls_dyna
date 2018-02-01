# VNC/LS-DYNA wrapper for DesignSafe on Stampede2
set -x
WRAPPERDIR=$( cd "$( dirname "$0" )" && pwd )

#License path on Stampede2
export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:/work/00410/huang/apps/ls-dyna_9.1.0/lsprepost/lib
export PATH=$PATH:/work/00410/huang/apps/ls-dyna_9.1.0/lsprepost/

echo job $JOB_ID execution at: `date`

# our node name
NODE_HOSTNAME=`hostname -s`
echo "running on node $NODE_HOSTNAME"

## experiment for vncpasswords
VNCP='${AGAVE_JOB_ID}'
#VNCPO=`/scratch/00849/tg458981/vncp $VNCP`
echo $VNCP > $HOME/.vnc/$VNCP.txt
VNCPO=`vncpasswd -f < $HOME/.vnc/$VNCP.txt > $HOME/.vnc/$VNCP.pwd` 

# VNC server executable
VNCSERVER_BIN=`which vncserver`
echo "using default VNC server $VNCSERVER_BIN"

# set memory limits to 95% of total memory to prevent node death
NODE_MEMORY=`free -k | grep ^Mem: | awk '{ print $2; }'`
NODE_MEMORY_LIMIT=`echo "0.95 * $NODE_MEMORY / 1" | bc`
ulimit -v $NODE_MEMORY_LIMIT -m $NODE_MEMORY_LIMIT
echo "memory limit set to $NODE_MEMORY_LIMIT kilobytes"

# set wayness, used for ibrun
WAYNESS=`echo $PE | perl -pe 's/([0-9]+)way/\1/;'`
echo "set wayness to $WAYNESS"

# launch VNC session with the session password set to the agave job id
VNC_DISPLAY=`$VNCSERVER_BIN -geometry 1280x800 -rfbauth $HOME/.vnc/$VNCP.pwd $@ 2>&1 | grep desktop | awk -F: '{print $3}'` 
#VNC_DISPLAY=`$VNCSERVER_BIN -geometry 1280x800 -rfbauth vncp.txt $@ 2>&1 | grep desktop | awk -F: '{print $3}'`
echo "got VNC display :$VNC_DISPLAY"

# todo: make sure this is a valid display, and that it is 1 or 2, since those are the only displays forwarded
# using our iptables scripts
if [ x$VNC_DISPLAY == "x" ]; then
    echo
    echo "===================================================="
    echo "   Error launching vncserver: $VNCSERVER"
    echo "   Please submit a ticket to the TACC User Portal"
    echo "   http://portal.tacc.utexas.edu/"
    echo "===================================================="
    echo
    exit 1
fi
LOCAL_VNC_PORT=`expr 5900 + $VNC_DISPLAY`
echo "local (compute node) VNC port is $LOCAL_VNC_PORT"

# fire up websockify to turn the vnc session connection into a websocket connection
WEBSOCKIFY_COMMAND="/home1/00832/envision/websockify/run --cert=/home1/00832/envision/.viscert/vis.2015.04.pem -D 5902 localhost:$LOCAL_VNC_PORT"
echo "websockify command: ${WEBSOCKIFY_COMMAND}"
WEBSOCKIFY_OUTPUT=`${WEBSOCKIFY_COMMAND}`
echo ${WEBSOCKIFY_OUTPUT}

# use the ranges 10000 - 29999; 30000 - 49999 for stampede2 
# mapping uses node number then rack number for mapping
LOGIN_VNC_PORT=`echo $NODE_HOSTNAME | perl -ne 'print (($2+1).$3.$1) if /c\d(\d\d)-(\d)(\d\d)/;'`
if `echo ${NODE_HOSTNAME} | grep -q c5`; then 
    # on a c500 node, bump the login port 
    LOGIN_VNC_PORT=$(($LOGIN_VNC_PORT + 400))
fi
echo "got login node VNC port $LOGIN_VNC_PORT"
# create reverse tunnel port to login nodes.  Make one tunnel for each login so the user can just
# connect to stampede2.tacc
for i in `seq 4`; do
   ssh -q -f -g -N -R $LOGIN_VNC_PORT:$NODE_HOSTNAME:$LOCAL_VNC_PORT login$i
done
echo "Created reverse ports on Stampede2 logins"
echo "Your VNC server is now running!"
echo "To connect via VNC client:  SSH tunnel port $LOGIN_VNC_PORT to stampede2.tacc.utexas.edu:$LOGIN_VNC_PORT"
echo "                            Then connect to localhost::$LOGIN_VNC_PORT"
#echo
#echo "OR:                         Connect directly to login1.longhorn.tacc.utexas.edu::$LOGIN_VNC_PORT"
#echo
# set display for X applications
export DISPLAY=":$VNC_DISPLAY"
# Warn the user when their session is about to close
# see if the user set their own runtime
#TACC_RUNTIME=`qstat -j $JOB_ID | grep h_rt | perl -ne 'print $1 if /h_rt=(\d+)/'`  # qstat returns seconds
TACC_RUNTIME=`squeue -l -j $SLURM_JOB_ID | grep $SLURM_QUEUE | awk '{print $7}'` # squeue returns HH:MM:SS
if [ x"$TACC_RUNTIME" == "x" ]; then
   TACC_Q_RUNTIME=`sinfo -p $SLURM_QUEUE | grep -m 1 $SLURM_QUEUE | awk '{print $3}'`
   if [ x"$TACC_Q_RUNTIME" != "x" ]; then
       # pnav: this assumes format hh:dd:ss, will convert to seconds below
       #       if days are specified, this won't work
       TACC_RUNTIME=$TACC_Q_RUNTIME
   fi
fi
if [ x"$TACC_RUNTIME" != "x" ]; then
   # there's a runtime limit, so warn the user when the session will die
   # give 5 minute warning for runtimes > 5 minutes
       H=$((`echo $TACC_RUNTIME | awk -F: '{print $1}'` * 3600))
       M=$((`echo $TACC_RUNTIME | awk -F: '{print $2}'` * 60))
       S=`echo $TACC_RUNTIME | awk -F: '{print $3}'`
       TACC_RUNTIME_SEC=$(($H + $M + $S))
   if [ $TACC_RUNTIME_SEC -gt 300 ]; then
           TACC_RUNTIME_SEC=`expr $TACC_RUNTIME_SEC - 300`
           sleep $TACC_RUNTIME_SEC && echo "$USER's VNC session on $VNC_DISPLAY will end in 5 minutes.  Please save your work now." | wall &
       fi
fi

# we need vglclient to run to have graphics across multi-node jobs
vglclient >& /dev/null &
VGL_PID=$!

# stampede2 specific port offset + 20,000 for websocket port from websockify
WEBSOCKET_PORT=$(($LOGIN_VNC_PORT + 20000))
# write job start time and duration (in hours) to file
#date +%s > .envision_job_start
#echo "4" > .envision_job_duration
#echo "success" > .envision_status
#agave callback to let it know the job is running
${AGAVE_JOB_CALLBACK_RUNNING}

#notifications sent to designsafe, designsafeci-dev, and requestbin
curl -k --data "event_type=VNC&host=vis.tacc.utexas.edu&port=$WEBSOCKET_PORT&address=vis.tacc.utexas.edu:$LOGIN_VNC_PORT&password=$VNCP&owner=${AGAVE_JOB_OWNER}" https://designsafeci-dev.tacc.utexas.edu/webhooks/ &
curl -k --data "event_type=VNC&host=vis.tacc.utexas.edu&port=$WEBSOCKET_PORT&address=vis.tacc.utexas.edu:$LOGIN_VNC_PORT&password=$VNCP&owner=${AGAVE_JOB_OWNER}" https://www.designsafe-ci.org/webhooks/ &
curl -k --data "event_type=VNC&host=vis.tacc.utexas.edu&port=$WEBSOCKET_PORT&address=vis.tacc.utexas.edu:$LOGIN_VNC_PORT&password=$VNCP&owner=${AGAVE_JOB_OWNER}" http://requestbin.agaveapi.co/v946vov9 &
# cd to the input directory and run the application with the runtime
#values passed in from the job request

cd ${workingDirectory}
CWD=${workingDirectory}

# run lsprepost
# vglrun lsprepost
# run an xterm for the user; execution will hold here; launch lsprepost as well
xterm -r -ls -geometry 80x24+10+10 -title '*** Exit this window to kill your VNC server ***' -e 'lsprepost'

# job is done!
echo "Killing VGL client"
kill $VGL_PID
echo "Killing VNC server"
vncserver -kill $DISPLAY

# wait a brief moment so vncserver can clean up after itself
sleep 5
echo job $_SLURM_JOB_ID execution finished at: `date`

cd ..
rm -rf $HOME/.vnc/$VNCP.pwd

if [ ! $? ]; then
        echo "VNC exited with an error status. $?" >&2
        ${AGAVE_JOB_CALLBACK_FAILURE}
        exit
fi
