package com.awhisper.prowlmirror

import kotlin.math.abs

enum class ScrollDirection(val wireName: String) {
    UP("up"),
    DOWN("down"),
}

data class ScrollCompletion(val requestID: String, val direction: ScrollDirection)

internal fun remoteScrollDirection(
    horizontal: Float,
    vertical: Float,
    startedAtTop: Boolean,
    startedAtBottom: Boolean,
    threshold: Float,
): ScrollDirection? {
    if (!horizontal.isFinite() || !vertical.isFinite() ||
        abs(vertical) < threshold || abs(vertical) <= abs(horizontal)) return null
    return when {
        vertical > 0 && startedAtTop -> ScrollDirection.UP
        vertical < 0 && startedAtBottom -> ScrollDirection.DOWN
        else -> null
    }
}
