#!/bin/bash

# Warning
if [ "$(id -u)" != 0 ]; then
	echo "Error: SuperUser privileges required to use this script."
	exit -1
fi

CHROOT=
BUILD_CHROOT=0
ISO=

##############################
# Process Arguments
##############################
while [ $# -gt 0 ]; do
    case $1 in
        --build-chroot)
			BUILD_CHROOT=1
			shift
			;;


        --chroot)
			CHROOT=$2
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
	-*)
			echo "Invalid arg: $1"
			exit 1
			;;
        *)
			break
			;;
    esac
done

ARCH=`arch`
if [ "$BUILD_ARCH" != "$ARCH" -a -z "$CHROOT" -a -z "$BUILD_CHROOT" ]; then
    echo "You need to build the DVD on a host with the same architecture (i386 or x86-64) as the DVD itself, or to specify a 'chroot' jail"
    exit -1
fi

####################################
# Configuration that often changes
####################################
BUILD_VERSION="3.5" #perfSONAR version
BUILD_OS_VERSION="6.7" #CentOS version

##############################
# Build Configuration
##############################
ISO_DOWNLOAD_SERVER="linux.mirrors.es.net"
BUILD="perfSONAR Toolkit"
BUILD_SHORT="pS-Toolkit"
BUILD_DATE=`date "+%Y-%m-%d"`
BUILD_ID=`date +"%Y%b%d"`
BUILD_OS="CentOS6"
BUILD_OS_NAME="CentOS"
BUILD_ISO_LABEL="pS-Toolkit"
BUILD_TYPE=FullInstall
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
	ISO="$SCRIPTS_DIRECTORY/../resources/$BUILD_OS_NAME-$BUILD_OS_VERSION-$BUILD_ARCH-minimal.iso"
	if [ ! -e "$ISO" ]; then
	    pushd $SCRIPTS_DIRECTORY/../resources
	    wget "http://$ISO_DOWNLOAD_SERVER/$BUILD_OS_NAME_LOWER/$BUILD_OS_VERSION/isos/$BUILD_ARCH/$BUILD_OS_NAME-$BUILD_OS_VERSION-$BUILD_ARCH-minimal.iso"
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
# Apply Patch to Kickstart
##############################
echo "Patching $KICKSTART_FILE."
pushd $KICKSTARTS_DIRECTORY > /dev/null 2>&1

cp $KICKSTART_FILE $PATCHED_KICKSTART
sed -i "s/\[BUILD_ARCH\]/$BUILD_ARCH/g" $PATCHED_KICKSTART
#uncomment arch specific lines
sed -i "s/#$BUILD_ARCH//g" $PATCHED_KICKSTART
popd > /dev/null 2>&1

##############################
# Build Chroot If Needed
##############################
if [ "$BUILD_CHROOT" == "1" ]; then
    if [ ! -x $SCRIPTS_DIRECTORY/build_chroot.sh ]; then
        echo "The script to build a chroot is missing"
        exit -1
    fi
    if [ -z "$CHROOT" ]; then
        CHROOT=`mktemp -d`
    fi
    $SCRIPTS_DIRECTORY/build_chroot.sh $CHROOT $BUILD_ARCH
fi

if [ -z "$CHROOT" ]; then
    CHROOT="/"
fi

##############################
# Mount ISO
##############################
TEMP_ISO_MNT=`mktemp -d`
TEMP_NEW_ISO_MNT=`mktemp -d`
mount -o loop $ISO $TEMP_ISO_MNT

########################################
# Copy ISO contents to working directory
########################################
rmdir $TEMP_NEW_ISO_MNT
cp -Ra $TEMP_ISO_MNT $TEMP_NEW_ISO_MNT
find $TEMP_NEW_ISO_MNT -name TRANS.TBL -exec rm -f {} \; -print
umount $TEMP_ISO_MNT
rm -rf $TEMP_ISO_MNT

########################################
# Download Custom Packages
########################################
pushd $TEMP_NEW_ISO_MNT/Packages
##
# clean out packages. we'll download what we want
rm kernel*
rm openssl*

##
#download new packages.
setarch $BUILD_ARCH yum --installroot=$CHROOT clean all
PKG_LIST_FILE=`mktemp`
python $SCRIPTS_DIRECTORY/yum_pkglist_from_ks.py -i $CHROOT $PATCHED_KICKSTART $PKG_LIST_FILE
DL_ARCH_LIST="$BUILD_ARCH"
if [ "$DL_ARCH_LIST" == i386 ]; then
    DL_ARCH_LIST="i386,i686"
fi
cat $PKG_LIST_FILE | uniq | xargs -r setarch $BUILD_ARCH yumdownloader --installroot=$CHROOT --resolve --archlist=$DL_ARCH_LIST
rm $PKG_LIST_FILE
if [ "$BUILD_ARCH" == "x86_64" ]; then
    # There is a bug in yumdownloader where it downloads both x86_64 and i686. 
    # Clean out those i686 rpms to save space on iso
    rm *.i686.rpm
fi
rm $PKG_LIST_FILE
popd

########################################
# Rebuild ISO Yum repo
########################################
#Update repodata
pushd $TEMP_NEW_ISO_MNT
DISCINFO=`head -1 .discinfo`
COMPDATA=`find repodata -name *${BUILD_ARCH}.xml`
##
# Hackiest two lines of entire script follow. Force groups file to download then copy it
setarch $BUILD_ARCH yum --installroot=$CHROOT groupinfo base > /dev/null
cp $CHROOT/var/cache/yum/${BUILD_ARCH}/6/base/gen/groups.xml $COMPDATA
createrepo -u "media://$DISCINFO" -g $COMPDATA .
popd

########################################
# Install kickstart and set as default
########################################
cp $PATCHED_KICKSTART $TEMP_NEW_ISO_MNT/ks.cfg
mv $PATCHED_KICKSTART $TEMP_NEW_ISO_MNT/isolinux/ks.cfg

pushd $TEMP_NEW_ISO_MNT/isolinux
mv initrd.img initrd.img.xz
xz --format=lzma initrd.img.xz --decompress
echo ks.cfg | cpio -c -o -A -F initrd.img
xz --format=lzma initrd.img
mv initrd.img.lzma initrd.img
popd

######################################################
# Update isolinux Configuration and Create Boot Logo
######################################################
echo "Updating isolinux configuration."
cat > $TEMP_NEW_ISO_MNT/isolinux/boot.msg <<EOF
perfSONAR Toolkit    Integrated by the perfSONAR Team  Build Date:
http://www.perfsonar.net/  Hit enter to continue    $BUILD_DATE
EOF

cat > $TEMP_NEW_ISO_MNT/isolinux/isolinux.cfg <<EOF
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
  append initrd=initrd.img ks=file:///ks.cfg
label vesa
  menu label Install the perfSONAR Toolkit in text mode
  kernel vmlinuz
  append initrd=initrd.img text xdriver=vesa nomodeset ks=file:///ks.cfg
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

########################################
# Make New ISO
########################################
NEW_ISO="$SCRIPTS_DIRECTORY/../resources/${BUILD_ISO_LABEL}-${BUILD_VERSION}-${BUILD_TYPE}-${BUILD_ARCH}-${BUILD_ID}.iso"
mkisofs -r -R -J -T -v -no-emul-boot -joliet-long -boot-load-size 4 -boot-info-table -input-charset UTF-8 -V "$BUILD_SHORT" -p "$0" -A "$BUILD" -b isolinux/isolinux.bin -c isolinux/boot.cat -x “lost+found” -o $NEW_ISO $TEMP_NEW_ISO_MNT
rm -rf $TEMP_NEW_ISO_MNT

########################################
# Implant md5 in ISO
########################################
echo "Implanting MD5 in ISO."
if [ -a /usr/bin/implantisomd5 ]; then
    /usr/bin/implantisomd5 $NEW_ISO
elif [ -a /usr/lib/anaconda-runtime/implantisomd5 ]; then
    /usr/lib/anaconda-runtime/implantisomd5 $NEW_ISO
else
    echo "Package isomd5 not installed."
fi

########################################
# Make sure ISO can run on USB sticks
########################################
echo "Running isohbyrid on ISO."
isohybrid $NEW_ISO

########################################
# Generate MD5
########################################
echo "Generating new MD5"
md5sum $NEW_ISO > ${NEW_ISO}.md5

########################################
# Output success
########################################
echo "$BUILD $BUILD_TYPE ISO created successfully."
echo "ISO file can be found in resources directory. Exiting..."
