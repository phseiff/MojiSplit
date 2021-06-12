#!/bin/bash

# Function to split an individual emoji sheet:

split_individual_emoji_sheet() {
  # Usage: Call with a path to an input image, bg_color1 and bg_color2 as input parameters.

  # Input values:
  INPUTIMAGE=$1  # <- The image we want to convert
  OUT_DIR=$2  # <- The dir we want to convert into

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

  if [[ "$KEEP_HOLES" == "false" ]]; then
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
  elif [[ "$KEEP_HOLES" == "true" ]]; then
    pass
    # ToDo: Make this
  fi

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

  # Function to make an image from a mask:
  mask_to_image() {
     f=$1
     factor=$2
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
     size_minus_padding=$(((PXSIZE - PADDING * 2) * factor / PXSIZE))
     size=$((PXSIZE * factor / PXSIZE))
     # echo "size minus padding: $size_minus_padding; size: $size"
     convert -background none "$OUT_DIR/$INPUTNAME.$seg.png" -resize "${size_minus_padding}x${size_minus_padding}!" "$OUT_DIR/$INPUTNAME.$seg.png";
     # add margin:
     convert -background none "$OUT_DIR/$INPUTNAME.$seg.png" -gravity center -extent "${size}x${size}"  "$OUT_DIR/$INPUTNAME.$seg.png";
  }

  # optimize image if possible:
  optimize_if_possible() {
    if command -v optipng &> /dev/null; then
      optipng -o7 -quiet "$1"
    fi
  }

  # Go over all masks and make an image from each of them:
  seg=0
  for f in "$temp"/mask_*png; do
    if [[ "$MAXSIZE" == "None" ]]; then
      mask_to_image "$f" "$PXSIZE"
    else
      lower_size_bound=1
      upper_size_bound="$PXSIZE"
      while true; do
        size_to_try=$(((upper_size_bound + lower_size_bound) / 2))
        # echo "Trying image size $size_to_try for $f."
        mask_to_image "$f" "$size_to_try"
        optimize_if_possible "$OUT_DIR/$INPUTNAME.$seg.png"

        filesize=$(stat -c%s "$OUT_DIR/$INPUTNAME.$seg.png")
        # echo "Resulting file size is $filesize."

        if (( "$filesize" <= "$MAXSIZE" )); then
          lower_size_bound="$size_to_try"
        elif (( "$filesize" > "$MAXSIZE" )); then
          upper_size_bound="$size_to_try"
        fi
        if (( upper_size_bound == lower_size_bound + 1 )); then
          # echo "Found a fitting size!"
          mask_to_image "$f" "$lower_size_bound"
          optimize_if_possible "$OUT_DIR/$INPUTNAME.$seg.png"
          break
        fi
      done
    fi

    ((seg++))
  done
}



# Parse additonal parameters:
POSITIONAL=()
BG_COLOR=None
BG_COLOR2=None
PXSIZE=512
PADDING=16
MAXSIZE=None
KEEP_HOLES=false
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
    --pxsize)
    PXSIZE="$2"
    shift
    shift
    ;;
    --padding)
    PADDING="$2"
    shift
    shift
    ;;
    --maxsize)
    MAXSIZE="$2"
    shift
    shift
    ;;
    --keep-holes-filled-with-bg-color)
    KEEP_HOLES="true"
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

# Convert maxsize to a byte number:
if [ "$MAXSIZE" != "None" ]; then
  if [[ "$MAXSIZE" == *B ]]; then
    MAXSIZE_UNIT=${MAXSIZE: -2}
    MAXSIZE=${MAXSIZE:: 2}
    if [[ "$MAXSIZE_UNIT" == "GB" ]]; then
      MAXSIZE=$((MAXSIZE * (10**9)))
    elif [[ "$MAXSIZE_UNIT" == "MB" ]]; then
      MAXSIZE=$((MAXSIZE * (10**6)))
    elif [[ "$MAXSIZE_UNIT" == "KB" ]]; then
      MAXSIZE=$((MAXSIZE * (10**3)))
    else
      echo "$MAXSIZE_UNIT is not a valid unit for a file size."
      exit 1
    fi
  fi
fi

# find out if the output is a dir or an image:
if [[ ( "$OUT_RAW" == *.png ) || ( "$OUT_RAW" == *.PNG ) ]]; then
  # use a temp dir and remember we want to make a montage from it:
  MAKE_MONTAGE=true
  OUT_DIR=$(mktemp -d 2>/dev/null || mktemp -d -t 'temp')
  function cleanup2 {
    cleanup
    rm -rf "$OUT_DIR"
  }
  trap cleanup2 EXIT
else
  OUT_DIR=$OUT_RAW
  MAKE_MONTAGE=false
fi

# Make temp dir & cleanup function:
temp="$OUT_DIR/temp"
if [[ "$MAKE_MONTAGE" == "false" ]]; then
  function cleanup {
    rm -r "$temp"
  }
  trap cleanup EXIT
else
  function cleanup {
    rm -r "$temp"
    rm -r "$OUT_DIR"
  }
  trap cleanup EXIT
fi

# empty the output dir:
if test -d "$OUT_DIR"; then
  rm -r "$OUT_DIR"
fi
mkdir "$OUT_DIR"

# find out if the input is one or multiple images:

if test -f "$INP_RAW"; then
   # one inp file:
   split_individual_emoji_sheet $INP_RAW $OUT_DIR

elif test -d "$INP_RAW"; then
   # one input folder:
   for f in $INP_RAW/*; do
     split_individual_emoji_sheet $f $OUT_DIR
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
