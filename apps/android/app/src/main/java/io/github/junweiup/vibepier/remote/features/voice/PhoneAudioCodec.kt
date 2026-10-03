package io.github.junweiup.vibepier.remote.features.voice

/** Independent IMA-ADPCM packets; packet loss never carries predictor damage forward. */
object PhoneAudioCodec {
    private val steps = intArrayOf(7,8,9,10,11,12,13,14,16,17,19,21,23,25,28,31,34,37,41,45,50,55,60,66,73,80,88,97,107,118,130,143,157,173,190,209,230,253,279,307,337,371,408,449,494,544,598,658,724,796,876,963,1060,1166,1282,1411,1552,1707,1878,2066,2272,2499,2749,3024,3327,3660,4026,4428,4871,5358,5894,6484,7132,7845,8630,9493,10442,11487,12635,13899,15289,16818,18500,20350,22385,24623,27086,29794,32767)
    private val shifts = intArrayOf(-1,-1,-1,-1,2,4,6,8)
    fun encode(pcm: ShortArray): ByteArray {
        require(pcm.size in intArrayOf(160, 320, 480, 960))
        var predictor = pcm[0].toInt()
        var index = 0
        val initialStep = kotlin.math.abs(pcm[1].toInt() - predictor) / 2
        while (index < 88 && steps[index] < initialStep) index++
        val out = ByteArray(4 + pcm.size / 2)
        out[0] = predictor.toByte(); out[1] = (predictor shr 8).toByte(); out[2] = index.toByte()
        for (i in 1 until pcm.size) {
            val step = steps[index]
            var difference = pcm[i].toInt() - predictor
            var nibble = if (difference < 0) 8 else 0
            difference = kotlin.math.abs(difference)
            var delta = step shr 3
            if (difference >= step) { nibble = nibble or 4; difference -= step; delta += step }
            if (difference >= step shr 1) { nibble = nibble or 2; difference -= step shr 1; delta += step shr 1 }
            if (difference >= step shr 2) { nibble = nibble or 1; delta += step shr 2 }
            predictor = (predictor + if (nibble and 8 != 0) -delta else delta).coerceIn(-32768, 32767)
            index = (index + shifts[nibble and 7]).coerceIn(0, 88)
            val position = 4 + (i - 1) / 2
            out[position] = (out[position].toInt() or (nibble shl (((i - 1) % 2) * 4))).toByte()
        }
        return out
    }
}
