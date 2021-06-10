#!/bin/bash

# Make temp dir:
temp=$(mktemp -d 2>/dev/null || mktemp -d -t 'temp')
function cleanup {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

# Function to split an individual emoji sheet:

split_individual_emoji_sheet() {
  # Usage: Call with a path to an input image, bg_color1 and bg_color2 as input parameters.

  # Input values:
  INPUTIMAGE=$1  # <- The image we want to convert
  OUT_DIR=$2  # <- The dir we want to convert into
  BG_COLOR=$3
  BG_COLOR2=$4

  INPUTNAME="$(basename $INPUTIMAGE)";
  INPUTNAME="$(cut -d'.' -f1 <<<$INPUTNAME)";

  # empty the temp dir:
  if test -d "$temp"; then
    rm -r "$temp"
  fi
  mkdir "$temp"

  increase_size_by_10px() {
      pic=$1
      width=$(identify -format "%w" $pic)+10
      height=$(identify -format "%h" $pic)+10
      convert $pic -gravity center -extent "${width}x${height}" $pic
  }

  decrease_size_by_10px() {
    pic=$1
    width=$(identify -format "%w" $pic)-10
    height=$(identify -format "%h" $pic)-10
    convert $pic -crop "${width}x${height}+5+5" $pic
  }

  fill_red_from_the_borders() {
    pic=$1
    convert $pic -fill red -draw "color 1,1 floodfill" -alpha off $pic
  }

  # Function to make color to alpha:
  color_to_alpha() {
    if [ "$2" != "None" ]; then
      convert $1 -background $2 -alpha remove -alpha off $1
      convert                        \
          $1               \
          \(                         \
             -clone 0                \
             -fill $2                \
             -colorize 10            \
          \)                         \
          \(                         \
             -clone 0,1              \
             -compose difference     \
             -composite              \
             -separate               \
             +channel                \
             -evaluate-sequence max  \
             -auto-level             \
          \)                         \
           -delete 1                 \
           -alpha off                \
           -compose over             \
           -compose copy_opacity     \
           -composite                \
          $1
    fi
  }

  # add alpha to background of input image:
  cp $INPUTIMAGE $temp/inputimage.png
  INPUTIMAGE=$temp/inputimage.png
  color_to_alpha $INPUTIMAGE $BG_COLOR

  # We make a simplified image with two colors; red for things that aren't part of an emoji, and white for
  #  things that are (including holes in emojis):

  # Make a mask that's blue wherever it isn't intransparent:
  convert $INPUTIMAGE -fill blue -colorize 100 $temp/only_alpha.png
  # Make the image larger:
  increase_size_by_10px $temp/only_alpha.png
  # Make every transparent part as long as it's connected to the border red:
  fill_red_from_the_borders $temp/only_alpha.png
  # Give the image back it's original size:
  decrease_size_by_10px $temp/only_alpha.png
  # Make the blue parts white:
  convert $temp/only_alpha.png -fuzz 60% -fill white -opaque blue $temp/only_alpha.png

  # We now divert the image into multiple masks for individual emojis:

  convert $temp/only_alpha.png -threshold 98% \
      -morphology dilate octagon                            \
      -define connected-components:area-threshold=800       \
      -define connected-components:verbose=true             \
      -connected-components 8 -auto-level PNG8:$temp/lumps.png
  convert $temp/lumps.png -fuzz 0% -fill \#fefefe -opaque white $temp/lumps.png

  mask=0
  for v in {0..256}; do
     ((l=v*256))
     ((h=l+256))
     mean=$(convert $temp/lumps.png -black-threshold "$l" -white-threshold "$h" -fill black -opaque white -threshold 1 -verbose info: | grep -c "mean: 0 ")
     if [ "$mean" -eq 0 ]; then
       convert $temp/lumps.png -black-threshold "$l" -white-threshold "$h" -fill black -opaque white -threshold 1 $temp/mask_$mask.png
       color_to_alpha $temp/mask_$mask.png black
       ((mask++))
     fi
  done
  montage -tile 4x $temp/mask_* $temp/montage_masks.png;

  # Function to make an image a square by evenly adding space around it:
  squarize()
  {
      pic=$1
      convert $pic -background none -trim +repage $pic
      width=$(identify -format "%w" $pic)
      height=$(identify -format "%h" $pic)
      new_dim=$((width > height ? width : height))
      convert $pic -background none -gravity center -extent "${new_dim}x${new_dim}" +repage $pic
  }

  # Go over all masks and make an image from each of them:
  seg=0
  for f in $temp/mask_*png; do
     # make the image:
     trim_coordinates=$(convert $f -format "%@" info:)
     convert $INPUTIMAGE -background none -crop "$trim_coordinates" $OUT_DIR/$INPUTNAME.$seg.png
     convert $f -crop "$trim_coordinates" $OUT_DIR/mask_trimmed.$seg.png
     convert $OUT_DIR/$INPUTNAME.$seg.png -background none \( +clone -channel a -fx 0 \) +swap $OUT_DIR/mask_trimmed.$seg.png -composite $OUT_DIR/$INPUTNAME.$seg.png
     rm $OUT_DIR/mask_trimmed.$seg.png
     # make white transparent:
     color_to_alpha "$OUT_DIR/$INPUTNAME.$seg.png" "$BG_COLOR2";
     # make it a square:
     squarize "$OUT_DIR/$INPUTNAME.$seg.png";
     # resize to the size we want:
     convert -background none "$OUT_DIR/$INPUTNAME.$seg.png" -resize 480x480\! "$OUT_DIR/$INPUTNAME.$seg.png";
     # add margin:
     convert -background none "$OUT_DIR/$INPUTNAME.$seg.png" -gravity center -extent "512x512"  "$OUT_DIR/$INPUTNAME.$seg.png";

     ((seg++))
  done
}



# Parse additonal parameters:
POSITIONAL=()
BG_COLOR=None
BG_COLOR2=None
while [[ $# -gt 0 ]]; do
key="$1"
case $key in
    -bg|--background)
    BG_COLOR="$2"
    shift
    shift
    ;;
    -bg2|--background2)
    BG_COLOR2="$2"
    shift
    shift
    ;;
    *)
    POSITIONAL+=("$1")
    shift
    ;;
esac
done

if [ "${#POSITIONAL[@]}" -ne 2 ]; then
  echo "You need to input two positional arguments"
  exit
fi
INP_RAW="${POSITIONAL[0]}"
OUT_RAW="${POSITIONAL[1]}"

# find out if the output is a dir or an image:
if [[ ( "$OUT_RAW" == *.png ) || ( "$OUT_RAW" == *.PNG ) ]]; then
  # use a temp dir and remember we want to make a montage from it:
  MAKE_MONTAGE=true
  OUT_DIR=$(mktemp -d 2>/dev/null || mktemp -d -t 'temp')
  function cleanup2 {
    cleanup
    rm -rf "OUT_DIR"
  }
  trap cleanup2 EXIT
else
  OUT_DIR=$OUT_RAW
  MAKE_MONTAGE=false
fi

# empty the output dir:
if test -d "$OUT_DIR"; then
  rm -r "$OUT_DIR"
fi
mkdir "$OUT_DIR"

# find out if the input is one or multiple images:

if test -f "$INP_RAW"; then
   # one inp file:
   split_individual_emoji_sheet $INP_RAW $OUT_DIR $BG_COLOR $BG_COLOR2

elif test -d "$INP_RAW"; then
   # one input folder:
   for f in $INP_RAW/*; do
     split_individual_emoji_sheet $f $OUT_DIR $BG_COLOR $BG_COLOR2
   done

else
   # not a valid output at all:
   echo "$INP_RAW is not a valid file or directory"
   exit
fi

# Make montage:
if [[ $MAKE_MONTAGE == "true" ]]; then
  montage -background none -tile 4x $OUT_DIR/* $OUT_RAW
fi
