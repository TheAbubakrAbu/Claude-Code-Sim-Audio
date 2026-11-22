// simtone: plays a short sine tone, or digital silence, from inside an iOS simulator.
//
// `simaudio doctor` runs it with `xcrun simctl spawn <udid> simtone <seconds> <dBFS|silent>` to
// prove where a simulator's sound really goes. "silent" opens the audio output and plays
// zeros: Core Audio shows the process playing to a device, and nobody can hear it even if the
// mute is broken. Built for the iOS simulator by build.sh.

#include <AudioToolbox/AudioToolbox.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef struct {
    double phase;
    double step;
    float amplitude;
} Tone;

static void fill(void *user, AudioQueueRef queue, AudioQueueBufferRef buffer) {
    Tone *tone = user;
    UInt32 frames = buffer->mAudioDataBytesCapacity / (2 * sizeof(float));
    float *out = buffer->mAudioData;
    for (UInt32 i = 0; i < frames; i++) {
        float value = tone->amplitude * (float)sin(tone->phase);
        tone->phase += tone->step;
        if (tone->phase > 2 * M_PI) tone->phase -= 2 * M_PI;
        out[2 * i] = value;
        out[2 * i + 1] = value;
    }
    buffer->mAudioDataByteSize = frames * 2 * sizeof(float);
    AudioQueueEnqueueBuffer(queue, buffer, 0, NULL);
}

int main(int argc, char **argv) {
    double seconds = argc > 1 ? atof(argv[1]) : 1.5;
    if (seconds <= 0 || seconds > 30) seconds = 1.5;
    Tone tone = {0, 2 * M_PI * 440.0 / 48000.0, 0};
    if (argc > 2 && strcmp(argv[2], "silent") != 0) {
        double level = atof(argv[2]);
        if (level > -6) level = -6;  // never loud, whatever is asked for
        tone.amplitude = (float)pow(10, level / 20);
    }

    AudioStreamBasicDescription format = {0};
    format.mSampleRate = 48000;
    format.mFormatID = kAudioFormatLinearPCM;
    format.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    format.mChannelsPerFrame = 2;
    format.mBitsPerChannel = 32;
    format.mBytesPerFrame = 8;
    format.mBytesPerPacket = 8;
    format.mFramesPerPacket = 1;

    AudioQueueRef queue = NULL;
    OSStatus status = AudioQueueNewOutput(&format, fill, &tone, NULL, NULL, 0, &queue);
    if (status != noErr) {
        fprintf(stderr, "simtone: could not open the audio output (%d)\n", (int)status);
        return 1;
    }
    for (int i = 0; i < 3; i++) {
        AudioQueueBufferRef buffer = NULL;
        status = AudioQueueAllocateBuffer(queue, 2048 * 8, &buffer);
        if (status != noErr) {
            fprintf(stderr, "simtone: could not allocate audio (%d)\n", (int)status);
            return 1;
        }
        fill(&tone, queue, buffer);
    }
    status = AudioQueueStart(queue, NULL);
    if (status != noErr) {
        fprintf(stderr, "simtone: could not start playing (%d)\n", (int)status);
        return 1;
    }
    usleep((useconds_t)(seconds * 1e6));
    AudioQueueStop(queue, true);
    AudioQueueDispose(queue, true);
    printf("simtone: played %.1f s\n", seconds);
    return 0;
}
