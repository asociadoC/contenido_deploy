#!/bin/bash


BAKEXT=`date +%Y-%m-%d_%H-%M`
EXT=`date +%Y_%m_%d`
WDIR=`pwd` 
BASEDIR="~/cms/$EXT"
LOCALDIRS="data data/db data/fs"
CON_BASE=/var/www/html/contenido/includes

for LOCALDIR in $LOCALDIRS; do
	if [ ! -d $DIR $LOCALDIR ]; then
		echo "creating local directory $LOCALDIR "
		mkdir -p $LOCALDIR
	fi
done

###
##
# FUNCTIONS
##
###

showHelp() {
cat <<EOF

Usage: $0 -s source -t target -a/d/f

        -s	dev|qa|live	specifies source system
        -t	dev|qa|live	specifies target sytem
	-a			do database and filesystem (implies -d -f)
	-d 			dump and import database only
	-f			filesystem only

EOF
}

shiftVars() {
	while read LINE; do

		VARN=`echo $LINE | awk -F"=" '{ print $1 }'`
		VARV=`echo $LINE | awk -F"=" '{ print $2 }'`
		eval "${2}_${VARN}=${VARV}" 

	done < $1
}

checkDir() {

	if ssh $1 "ls $BASEDIR >/dev/null 2>&1"; then
		return 0
	else 
		ssh $1 "mkdir -p $BASEDIR "
		checkDir $1 
	fi
}

getDbPws() {

	SRC_DB_PASS=`ssh $SRC_FS_HOST "grep contenido_password $CON_BASE/config.php "` 
	SRC_DB_PASS=`echo $SRC_DB_PASS | awk -F"= " '{ print $2 }' | sed "s/.$//" `

	TGT_DB_PASS=`ssh $TGT_FS_HOST "grep contenido_password $CON_BASE/config.php "` 
	TGT_DB_PASS=`echo $TGT_DB_PASS | awk -F"= " '{ print $2 }' | sed "s/.$//" `
}

doDump() {

	checkDir $SRC_FS_HOST

	SRC_DB_FILENAME="$SRC_DB_NAME-$EXT.sql"

	# checking remote file
        if ssh $SRC_FS_HOST "ls $SRC_DB_FILENAME >/dev/null 2>&1 " ; then
                echo "remote source dump $SRC_DB_FILENAME on $SRC_FS_HOST existing, moving ..."
		ssh $SRC_FS_HOST "mv $SRC_DB_FILENAME $SRC_DB_FILENAME.$BAKEXT"
        fi

        echo "dumping database to $SRC_DB_FILENAME on $SRC_FS_HOST"

        if ssh $SRC_FS_HOST "( sudo mysqldump --add-drop-table --dump-date -h $SRC_DB_HOST -u $SRC_DB_USER -p$SRC_DB_PASS $SRC_DB_NAME > ~/$SRC_DB_FILENAME )" ; then
		echo "dump ok"
	else 
		echo "dump NOK"
	fi
}

pullDump() {
        ### pull dump from source server
	# check local file

        if [ -f ./data/db/$SRC_DB_FILENAME ] ; then
                echo "local dump $SRC_DB_FILENAME existing, moving ..."
		mv ./data/db/$SRC_DB_FILENAME ./data/db/$SRC_DB_FILENAME.$BAKEXT
        fi
	echo "fetching dump"
	scp $SRC_FS_HOST:~/$SRC_DB_FILENAME ./data/db/
}

editDump() {
        ### edit DUMP
        echo -n "editing dump .. replacing $SRC_LI_URL with $TGT_LI_URL "

	if [ -z $TGT_LI_URL ]; then
		echo "string is empty"
		SRC_LI_URL=".$SRC_LI_URL"
	fi

        if sed "s/$SRC_LI_URL/$TGT_LI_URL/g" ./data/db/$SRC_DB_FILENAME > ./data/db/$TARSYS-$SRC_DB_FILENAME.tmp ; then
                echo "success"
        else
                echo "failed"
        fi

        echo -n "editing dump .. replacing $SRC_DA_URL with $TGT_DA_URL "
        if sed "s/$SRC_DA_URL/$TGT_DA_URL/g" ./data/db/$TARSYS-$SRC_DB_FILENAME.tmp > ./data/db/$TARSYS-$SRC_DB_FILENAME ; then
                echo "success"
        else
                echo "failed"
        fi
}

pushDump() {

	checkDir $TGT_FS_HOST

        ### push dump
        if ssh $TGT_FS_HOST "ls $BASEDIR/$TARSYS-$SRC_DB_FILENAME >/dev/null 2>&1 " ; then
		echo "remote target dump $BASEDIR/$TARSYS-$SRC_DB_FILENAME on $TGT_FS_HOST existing, moving ..."
		ssh $TGT_FS_HOST "mv $BASEDIR/$TARSYS-$SRC_DB_FILENAME $BASEDIR/$TARSYS-$SRC_DB_FILENAME.$BAKEXT"
	fi
	scp ./data/db/$TARSYS-$SRC_DB_FILENAME $TGT_FS_HOST:$BASEDIR
}

importDump() {
        ### import dump on target database
	echo -n "create backup of $TGT_DB_NAME now ? <y|n>"
	read ANSWER;
	case $ANSWER in 
		y|Y)
			createDbBackup
		;;
		n|N)
			echo "continuing without backup"
		;;
	esac

        echo -n "Import database into $TGT_DB_NAME NOW ? <y|n> "
        read ANSWER;

        case $ANSWER in
                y|Y)
                        echo "Starting import, this will take some time .. (10-30 sec)" 
                        ## import dump
                        ssh $TGT_FS_HOST "( sudo mysql -h $TGT_DB_HOST -u $TGT_DB_USER -p$TGT_DB_PASS -D $TGT_DB_NAME < $BASEDIR/$TARSYS-$SRC_DB_FILENAME )"
                        ## truncate table con_code
                        echo "truncate table con_code (contenido generated html code cache) "
                        ssh $TGT_FS_HOST "( sudo mysql -h $TGT_DB_HOST -u $TGT_DB_USER -p$TGT_DB_PASS -D $TGT_DB_NAME -e 'TRUNCATE TABLE con_code;')"
                        ## truncate table con_inuse
                        echo "truncate table con_inuse (if an article was still in use in backend)"
                        ssh $TGT_FS_HOST "( sudo mysql -h $TGT_DB_HOST -u $TGT_DB_USER -p$TGT_DB_PASS -D $TGT_DB_NAME -e 'TRUNCATE TABLE con_inuse;')"
                        ## truncate con_phplib_active_sessions
                        echo "truncate table active sessions (if someone was logged in in backend while dumping database) "
                        ssh $TGT_FS_HOST "( sudo mysql -h $TGT_DB_HOST -u $TGT_DB_USER -p$TGT_DB_PASS -D $TGT_DB_NAME -e 'TRUNCATE TABLE con_phplib_active_sessions;')"
                ;;
                n|N)
                        echo "ok, will not import yet .. dont forget to do it yourself later !"
                ;;
                *)
                echo "did not understand .. exit"
                exit 0
                ;;
        esac
}

createDbBackup() {
	### create db backup of target DB 
        BU_DB_FILENAME="$BASEDIR/BACKUP_$TGT_DB_NAME-$EXT.sql"

        echo "dumping database $TGT_DB_NAME to $BU_DB_FILENAME on $TGT_FS_HOST"

        # checking remote file
        if ssh $TGT_FS_HOST "ls $BU_DB_FILENAME >/dev/null 2>&1 " ; then
                echo "remote backup dump $BU_DB_FILENAME on $TGT_FS_HOST already existing, moving ..."
                ssh $TGT_FS_HOST "mv $BU_DB_FILENAME $BU_DB_FILENAME.$BAKEXT"
        fi

        ssh $TGT_FS_HOST "( sudo mysqldump --add-drop-table --dump-date -h $TGT_DB_HOST -u $TGT_DB_USER -p$TGT_DB_PASS $TGT_DB_NAME > $BU_DB_FILENAME )"
	
}

createDir() {
        # Filesystem
        FS_TAR=data/fs/$EXT

        if [ -d $FS_TAR ] ; then
		mv $FS_TAR $FS_TAR-$BAKEXT
	fi
	mkdir -p $FS_TAR
}

pullFiles() {
        ### pull files from source server
        #### vhosts
        cd $FS_TAR
        echo "pulling vhosts contents from $SRC_FS_HOST, please be patient .."
        ssh $SRC_FS_HOST "( cd /var/www/ ; sudo tar cf - vhosts --exclude=version )" | sudo tar xf -
        echo "pulling contenido plugins from $SRC_FS_HOST, please be patient .."
        ssh $SRC_FS_HOST "( cd /var/www/html/contenido/ ; sudo tar cf - plugins )" | sudo tar xf -
}

cleanCache() {
        ### empty cache directories
        echo "cleaning caches in local copy $FS_TAR "
	cd $WDIR
        for DIR in `find $FS_TAR -name "cache" -type d ` ; do
                sudo rm -f $DIR/*
        done
}

createBackup() {
        ### create backup on traget server(s)

	checkDir $TGT_FS_HOST

        echo -n "creating backup $BASEDIR/vhosts_$EXT.tar.bz2 on $TGT_FS_HOST ... "
        if ssh $TGT_FS_HOST "( cd /var/www ; sudo tar cjf $BASEDIR/vhosts_$EXT.tar.bz2 vhosts )" ; then
		echo "success "
	else 
		echo "fail"
	fi
}

pushFiles() {
        ### push copy to target server(s)
	cd $WDIR
        cd $FS_TAR

        echo -n "copy files to remote server now ? <y|n> "
        read ANSWER;

        case $ANSWER in
                y|Y)
			for TGT_FS_SERVER in $TGT_FS_SERVERS; do
				echo "pushing vhosts to $TGT_FS_SERVER .. "
				sudo tar cf - vhosts | ssh $TGT_FS_SERVER "( cd /var/www ; sudo tar xf - )"
				echo "pushing contenido plugins to $TGT_FS_SERVER .. "
				sudo tar cf - plugins | ssh $TGT_FS_SERVER "( cd /var/www/html/contenido ; sudo tar xf - )"
			done
                ;;
                n|N)
                        echo "ok, will not push files yet .. dont forget to do it yourself later !"
                ;;
                *)
                echo "did not understand .. exit"
                exit 0
                ;;
        esac
	
}

###
##
# Collector Functions !!
## 
###

doDatabase() {
	getDbPws
	doDump
	pullDump
	editDump
	pushDump
	importDump
}

doFilesystem() {
	createDir
	pullFiles
	cleanCache
	createBackup
	pushFiles
}

while getopts "s:t:adf" opt; do
        case $opt in
                s)
			SRCSYS=$OPTARG
                        SOURCE=conf/$OPTARG.conf
			shiftVars $SOURCE SRC

			if [ ! -f $SOURCE ]; then
				echo "$SOURCE not found"
				exit 1
			fi
                ;;
                t)
			TARSYS=$OPTARG
			TARGET=conf/$OPTARG.conf

			if [ ! -f $TARGET ]; then
				echo "$TARGET not found"
				exit 1
			fi
	
			CODE=`date +%d%m`
			CODE=`echo $CODE|sed 's/^0*//'`
			CODE=$(($CODE * 2))


			if [ $OPTARG == "live" ]; then
				echo
				echo "WARNING !"
				echo "#-#-#-#-#-#-#-#"
				echo "to make sure you are aware of what you are doing, "
				echo -n "type the following 4-digit security code to continue ## $CODE ## : "
			
				read ANSWERCODE;

				if [ ! $ANSWERCODE == $CODE ]; then
					echo "wrong code !"
					exit 0
				fi
			fi

			if [ $OPTARG == "live_"$CODE ]; then
				TARSYS=live
				TARGET=conf/live.conf
			fi
				
			if [ $SRCSYS == $TARSYS ]; then
				echo "very funny .. really : $SRCSYS to $TARSYS ... "
				exit 1
			fi

			shiftVars $TARGET TGT
                ;;
		a)
			doDatabase
			doFilesystem
		;;
		f)
			doFilesystem
		;;
		d)
			doDatabase
		;;
		\?)
			showHelp
		;;
		*)
			showHelp
		;;
        esac
done

exit 0
