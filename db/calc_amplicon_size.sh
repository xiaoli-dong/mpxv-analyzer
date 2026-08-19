awk '
{
    if ($4 ~ /LEFT/) {
        split($4,a,"_LEFT")
        id=a[1]
        left_start[id]=$2
    }
    else if ($4 ~ /RIGHT/) {
        split($4,a,"_RIGHT")
        id=a[1]
        right_end[id]=$3

        size=right_end[id]-left_start[id]+1
        print id "\t" left_start[id] "\t" right_end[id] "\t" size
    }
}
' bccdc-mpox_2500_v2.3.0_primer.bed
