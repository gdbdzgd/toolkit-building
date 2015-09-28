#!/bin/bash

# Warning
if [ "$(id -u)" != 0 ]; then
	echo "Warning: SuperUser privileges required to use this script."
	read -p "Press [Enter] key to continue..."
fi

##############################
# Process Arguments
##############################
while [ $# -gt 0 ]; do
    case $1 in
        --arch)
			BUILD_ARCH=$2
			if [ -z $BUILD_ARCH ]; then
				echo "No architecture specified, exiting..."
				exit 1
			fi
			if [ ! $BUILD_ARCH = "i386" -a ! $BUILD_ARCH = "x86_64" ]; then
				echo "Invalid architecture specified, exiting..."
				exit 1
			fi
			shift
			shift
			;;
		--iso)
			ISO=$2
			if [ -z $ISO ]; then
				echo "No ISO file specified, exiting..."
				exit 1
			fi
			shift
			shift
			;;
		-*)
			echo "Invalid arg: $1"
			exit 1
			;;
        *)
			break
			;;
    esac
done

####################################
# Configuration that often changes
####################################
BUILD_VERSION="3.5" #perfSONAR version
BUILD_OS_VERSION="6.7" #CentOS version

##############################
# Build Configuration
##############################
ISO_DOWNLOAD_SERVER="linux.mirrors.es.net"
BUILD=pS-Toolkit
BUILD_SHORT=pS-Toolkit
BUILD_DATE=`date "+%Y-%m-%d"`
BUILD_ID=`date +"%Y%b%d"`
BUILD_OS="CentOS6"
BUILD_OS_NAME="CentOS"
BUILD_TYPE=NetInstall
if [ -z $BUILD_ARCH ]; then
	BUILD_ARCH=x86_64
fi

BUILD_OS_LOWER=`echo $BUILD_OS | tr '[:upper:]' '[:lower:]'`
BUILD_OS_NAME_LOWER=`echo $BUILD_OS_NAME | tr '[:upper:]' '[:lower:]'`
BUILD_TYPE_LOWER=`echo $BUILD_TYPE | tr '[:upper:]' '[:lower:]'`
# Assume we're running from the 'scripts' directory
SCRIPTS_DIRECTORY=`dirname $(readlink -f $0)`
mkdir -p $SCRIPTS_DIRECTORY/../resources
if [ -z "$ISO" ]; then
	ISO="$SCRIPTS_DIRECTORY/../resources/$BUILD_OS_NAME-$BUILD_OS_VERSION-$BUILD_ARCH-$BUILD_TYPE_LOWER.iso"
	if [ ! -e "$ISO" ]; then
	    pushd $SCRIPTS_DIRECTORY/../resources
	    wget "http://$ISO_DOWNLOAD_SERVER/$BUILD_OS_NAME_LOWER/$BUILD_OS_VERSION/isos/$BUILD_ARCH/$BUILD_OS_NAME-$BUILD_OS_VERSION-$BUILD_ARCH-$BUILD_TYPE_LOWER.iso"
	    popd
	fi
fi

##############################
# Kickstart Configuration
##############################
KICKSTARTS_DIRECTORY=$SCRIPTS_DIRECTORY/../kickstarts
KICKSTART_FILE=$BUILD_OS_LOWER-$BUILD_TYPE_LOWER.cfg
PATCHED_KICKSTART=`mktemp`

##############################
# ISO Configuration
##############################
ISO_MOUNT_POINT=/mnt/iso
OUTPUT_ISO=$BUILD-$BUILD_VERSION-$BUILD_TYPE-$BUILD_ARCH-$BUILD_ID.iso
OUTPUT_MD5=$OUTPUT_ISO.md5
LOGO_FILE=$SCRIPTS_DIRECTORY/../images/$BUILD-Splash-$BUILD_VERSION.gif

# Caches
CACHE_DIRECTORY=/var/cache/live

##############################
# Apply Patch
##############################
echo "Patching $KICKSTART_FILE."
pushd $KICKSTARTS_DIRECTORY > /dev/null 2>&1

# Set correct build architechture
cp $KICKSTART_FILE $PATCHED_KICKSTART
sed -i "s/\[BUILD_ARCH\]/$BUILD_ARCH/g" $PATCHED_KICKSTART
popd > /dev/null 2>&1

##############################
# Create Extra Loop Devices
##############################
echo "Creating extra loop devices."
MAX_LOOPS=256
NUM_LOOPS=$((`/sbin/losetup -a | wc -l` + 8))
NUM_LOOPS=$(($NUM_LOOPS + (16 - $NUM_LOOPS % 16)))
if [ $NUM_LOOPS -gt $MAX_LOOPS ]; then
	echo "Couldn't find enough unused loop devices."
	exit -1
fi
/sbin/MAKEDEV -m $NUM_LOOPS loop

##############################
# Create Mount Point and Mount ISO
##############################
pushd $SCRIPTS_DIRECTORY/../resources > /dev/null 2>&1
echo "Creating mount point for ISO: $ISO_MOUNT_POINT."
mkdir -p $ISO_MOUNT_POINT
if [ $? != 0 ]; then
	echo "Couldn't create mount point: $ISO_MOUNT_POINT."
	exit -1
fi

echo "Mounting ISO file."
mount -t iso9660 -o loop $ISO $ISO_MOUNT_POINT
if [ $? != 0 ]; then
	echo "Couldn't mount $ISO at $ISO_MOUNT_POINT."
	exit -1
fi

##############################
# Create Temporary Directory and Build NetInstall
##############################
echo "Creating temporary directory."
TEMP_DIRECTORY=`mktemp -d`
if [ ! -d $TEMP_DIRECTORY ]; then
	echo "Couldn't create temporary directory."
	exit -1
fi

echo "Building $BUILD_TYPE in $TEMP_DIRECTORY."
rm -rf $TEMP_DIRECTORY
cp -Ra $ISO_MOUNT_POINT $TEMP_DIRECTORY

mv $PATCHED_KICKSTART $TEMP_DIRECTORY/isolinux/$BUILD_OS_LOWER-$BUILD_TYPE_LOWER.cfg

echo "Placing kickstart into initrd.img"
pushd $TEMP_DIRECTORY/isolinux
mv initrd.img initrd.img.xz
xz --format=lzma initrd.img.xz --decompress
echo $BUILD_OS_LOWER-$BUILD_TYPE_LOWER.cfg | cpio -c -o -A -F initrd.img
xz --format=lzma initrd.img
mv initrd.img.lzma initrd.img
rm $BUILD_OS_LOWER-$BUILD_TYPE_LOWER.cfg
popd

##############################
# Update isolinux Configuration and Create Boot Logo
##############################
echo "Updating isolinux configuration."
cat > $TEMP_DIRECTORY/isolinux/boot.msg <<EOF
17splash.lss
perfSONAR Toolkit    Integrated by the perfSONAR Team  Build Date:
http://www.perfsonar.net  Hit enter to continue    $BUILD_DATE
EOF

cat > $TEMP_DIRECTORY/isolinux/isolinux.cfg <<EOF
default vesamenu.c32
#prompt 1
timeout 600

display boot.msg

menu background splash.jpg
menu title Welcome to perfSONAR Toolkit $BUILD_VERSION!
menu color border 0 #ffffffff #00000000
menu color sel 7 #ffffffff #ff000000
menu color title 0 #ffffffff #00000000
menu color tabmsg 0 #ffffffff #00000000
menu color unsel 0 #ffffffff #00000000
menu color hotsel 0 #ff000000 #ffffffff
menu color hotkey 7 #ffffffff #ff000000
menu color scrollbar 0 #ffffffff #00000000

label linux
  menu label ^Install the perfSONAR Toolkit
  menu default
  kernel vmlinuz
  append initrd=initrd.img ks=file:///$BUILD_OS_LOWER-$BUILD_TYPE_LOWER.cfg
label vesa
  menu label Install the perfSONAR Toolkit in text mode
  kernel vmlinuz
  append initrd=initrd.img text xdriver=vesa nomodeset ks=file:///$BUILD_OS_LOWER-$BUILD_TYPE_LOWER.cfg
label rescue
  menu label ^Rescue installed system
  kernel vmlinuz
  append initrd=initrd.img rescue
label local
  menu label Boot from ^local drive
  localboot 0xffff
label memtest86
  menu label ^Memory test
  kernel memtest
  append -
EOF

echo "Building boot logo file."
convert $LOGO_FILE ppm:- | ppmtolss16 '#FFFFFF=7' > $TEMP_DIRECTORY/isolinux/splash.lss
convert -depth 16 -colors 65536 $LOGO_FILE $TEMP_DIRECTORY/isolinux/splash.png
mv $TEMP_DIRECTORY/isolinux/splash.png $TEMP_DIRECTORY/isolinux/splash.jpg

##############################
# Create new ISO and MD5 and Cleanup
##############################
echo "Generating new ISO: $OUTPUT_ISO"
mkisofs -r -R -J -T -v -no-emul-boot -boot-load-size 4 -boot-info-table -input-charset UTF-8 -V "$BUILD_SHORT" -p "$0" -A "$BUILD" -b isolinux/isolinux.bin -c isolinux/boot.cat -x “lost+found” -o $OUTPUT_ISO $TEMP_DIRECTORY
if [ $? != 0 ]; then
	echo "Couldn't generate $OUTPUT_ISO."
	exit -1
fi

echo "Implanting MD5 in ISO."
if [ -a /usr/bin/implantisomd5 ]; then
    /usr/bin/implantisomd5 $OUTPUT_ISO
elif [ -a /usr/lib/anaconda-runtime/implantisomd5 ]; then
    /usr/lib/anaconda-runtime/implantisomd5 $OUTPUT_ISO
else
    echo "Package isomd5 not installed."
fi

# Make sure the ISO can boot on USB sticks
isohybrid $OUTPUT_ISO

echo "Generating new MD5: $OUTPUT_MD5."
md5sum $OUTPUT_ISO > $OUTPUT_MD5

echo "Cleaning up $TEMP_DIRECTORY."
rm -rf $TEMP_DIRECTORY

echo "Unmounting temp ISO file."
umount -l $ISO_MOUNT_POINT
popd > /dev/null 2>&1

echo "$BUILD $BUILD_TYPE ISO created successfully."
echo "ISO file can be found in resources directory. Exiting..."
