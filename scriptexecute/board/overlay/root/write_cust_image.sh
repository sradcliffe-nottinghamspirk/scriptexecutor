#!/bin/sh

# Usage: write_cust_image.sh IMAGEFILE
#
# Write an eMMC image from a .zip or .xz compressed file image

# Script Options:
# -----------------------------
# Uncomment to skip operator confirmation prior to writing:
#DONT_ASK_TO_CONFIRM_WRITE="1"

# Uncomment to always perform readback verification of eMMC
DO_IMAGE_READBACK="1"
# -----------------------------

cecho()
{
  RED='\033[0;31m'
  GRN='\033[0;32m'
  YEL='\033[0;33m'
  BYEL='\033[1;33m'
  NC='\033[0m'
  REV='\033[0;7m'

  case $1 in
    FAIL)
      COLOR=$RED ;;
    PASS)
      COLOR=$GRN ;;
    WARN)
      COLOR=$BYEL ;;
    NOTE)
      COLOR=$YEL ;;
    YN)
      COLOR=$REV ;;
    *)
      COLOR=$NC ;;
  esac

  printf "${COLOR}${2}${NC}"
}

clear_line()
{
  CLRLINE='\033[K'

  printf "\r${CLRLINE}"
}

prompt_yn()
{
  prompt="${1} (y,n)?"
  len=${#prompt}

  while [ 1 ]; do
    cecho "YN" "$prompt"
    read -r resp
    clear_line

    if [ "${resp}" = "n" -o "${resp}" = "N" ]  ; then
      result=1
      break
    elif [ "${resp}" = "y" -o "${resp}" = "Y" ]  ; then
      result=0
      break
    else
      cecho "YEL" "-- Please input y(Y) or n(N)! --\n"
    fi
  done

  return $result
}

if [ $# -lt "1" ]; then
  cecho "NOTE" "Usage: Please specify zip or xz file containing the customer image\n"
  exit 1
fi

ZIPFILE="$1"
ZIPPATH="$(dirname $1)/"
ZIPEXT="${ZIPFILE##*.}"
EMMC=/dev/mmcblk0
EMMC1=/dev/mmcblk0p1
TMP_SHA256=/tmp/tmp.sha256
WRITE_TIME_IN_SEC=$((35*1024*1024))
READBACK_TIME_IN_SEC=$((70*1024*1024))

if [ "$ZIPEXT" = "xz" ]; then
  ZIPEXTRACT="xzcat"
  ZIPLIST="xzcat -l --robot"
else
  ZIPEXTRACT="unzip -p"
  ZIPLIST="unzip -l"
fi

verify_image_file ()
{
  $ZIPEXTRACT $ZIPFILE | sha256sum > "$TMP_SHA256"
  cecho "NOTE" "SHA256 sum of the customer image file '$FILE_NAME':\n"
  cat "$TMP_SHA256"
  prompt_yn "Does SHA256 sum match expected?"
  if [ $? -ne 0 ]; then
    return 1
  else
    mv "$TMP_SHA256" "$ZIPPATH$FILE_NAME.sha256"
    return 0
  fi
}

unmount_image ()
{
  umount $EMMC1 2> /dev/null
}

verify_image ()
{
  # perform SHA256 checksum on eMMC content
  unmount_image
  sh -c "<$EMMC head -c $IMAGE_SIZE_IN_BYTES | sha256sum > $TMP_SHA256"
  sync
  diff $TMP_SHA256 "$ZIPPATH$FILE_NAME.sha256"
  if [ $? -ne 0 ]; then
    return 1
  else
    return 0
  fi
}

find_in_string ()
{
  # Assuming a whitespace delimited string, find the 'count' substring
  # if 'count' is negative, will search from end of string
  count=${1}
  str=${2}
  cur_count=0

  # Purposely don't enclose in double-quotes, to remove extra spaces
  SLICE=$(echo $str)

  while [ $cur_count -ne $count ]; do
    if [ $count -lt 0 ]; then
      # Starting from end
      SLICE="${SLICE% *}"
      cur_count=$((cur_count-1))
    else
      # Start from beginning
      SLICE="${SLICE#* }"
      cur_count=$((cur_count+1))
    fi
  done

  if [ $count -lt 0 ]; then
    resp="${SLICE##* }"
  else
    resp="${SLICE%% *}"
  fi

  echo "$resp"
}

if [ ! -f "$ZIPFILE" ]; then
  cecho "FAIL" "Error: $ZIPFILE not found\n"
  exit 2
fi

# Verify zip has one file and record its length
zipfilelist=$($ZIPLIST $ZIPFILE)
if [ $? -ne 0 ]; then
  cecho "FAIL" "$(basename $ZIPFILE) does not appear to be a valid archive\n"
  exit 3
elif [ "$ZIPEXT" = "xz" ]; then
    FILE_NAME="$(find_in_string 1 "$zipfilelist")"
    FILE_NAME="$(basename $FILE_NAME)"
    FILE_NAME="${FILE_NAME%.*}"
    IMAGE_SIZE_IN_BYTES="$(find_in_string 6 "$zipfilelist")"
else
    FILE_NAME="$(find_in_string -5 "$zipfilelist")"
    IMAGE_SIZE_IN_BYTES="$(find_in_string -2 "$zipfilelist")"
    NUM_ZIP_FILES="$(find_in_string -1 "$zipfilelist")"
    if [ "$NUM_ZIP_FILES" -ne "1" ]; then
      cecho "FAIL" "Error: Zip file must only have one file, the image file\n"
      cecho "${zipfilelist}\n"
      exit 5
    fi
fi

cecho "NOTE" "Found image file: $FILE_NAME size=$IMAGE_SIZE_IN_BYTES\n"

if [ ! -f "$ZIPPATH$FILE_NAME.sha256" ]; then
  cecho "WARN" "SHA256 signature of image not found. Must perform an initial image validation.\n"
  prompt_yn "Ready to perform validation?"
  if [ $? -ne 0 ]; then
    exit 9
  fi

  cecho "NOTE" "Verifying image file. This may take a few minutes..\n"
  verify_image_file
  if [ $? -ne 0 ]; then
    cecho "FAIL" "Error: Image file not validated, cannot continue.\n"
    exit 6
  fi
  DO_IMAGE_READBACK="1"
fi

if [ "$DONT_ASK_TO_CONFIRM_WRITE" != "1" ]; then
  # Ask operator for confirmation (check can be removed if this script is only called after all tests pass)
  prompt_yn "Did all tests pass and safe to write customer image?"
  if [ $? -ne 0 ]; then
    exit 10
  fi
fi

ESTIMATE=$(($IMAGE_SIZE_IN_BYTES/$WRITE_TIME_IN_SEC))

cecho "NOTE" "Programming image, takes about $ESTIMATE secs..\n"

# un-mount eMMC FAT partition (/boot)
unmount_image

# write image from USB flash to eMMC, uncompressing on the fly,
$ZIPEXTRACT $ZIPFILE | dd of=$EMMC bs=4M conv=fsync

if [ "$DO_IMAGE_READBACK" = "1" ]; then
  ESTIMATE=$(($IMAGE_SIZE_IN_BYTES/$READBACK_TIME_IN_SEC))
  sleep 1
  cecho "NOTE" "Performing eMMC image verification, takes about $ESTIMATE secs..\n"
  verify_image
  if [ $? -ne 0 ]; then
    cecho "FAIL" "Error: Readback of customer image did not match.\n"
    exit 20
  else
    cecho "PASS" "Success: eMMC image matches the image file.\n"
  fi
else
  cecho "PASS" "OK: Image written to eMMC.\n"
fi

exit 0
