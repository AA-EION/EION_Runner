/*
    Canary test suite.

    A plain console runner rather than a test framework, so the canary has
    exactly one external dependency (JUCE) and the CI job needs nothing
    installed to run it. Exit code 0 means every check passed; any failure
    prints the file and line and exits non-zero, which is what the workflow
    gates on.
*/

#include <juce_audio_processors/juce_audio_processors.h>
#include <juce_audio_basics/juce_audio_basics.h>
#include <juce_events/juce_events.h>

#include "PluginProcessor.h"

#include <cmath>
#include <cstdio>
#include <string>
#include <vector>

namespace
{
    int checksRun    = 0;
    int checksFailed = 0;

    void reportCheck (bool passed, const char* expression, const char* description,
                      const char* file, int line)
    {
        ++checksRun;

        if (passed)
        {
            std::printf ("  [ ok ] %s\n", description);
            return;
        }

        ++checksFailed;
        std::printf ("  [FAIL] %s\n         expression: %s\n         at %s:%d\n",
                     description, expression, file, line);
    }

    constexpr double testSampleRate = 48000.0;

    /*  Several checks below assert *exact* silence — a gain of zero must produce
        a bit-exact 0.0f, not "small". Exact comparison is the assertion, not an
        oversight, so -Wfloat-equal is suppressed here and only here rather than
        weakening the checks to a tolerance that would let a real bug through.
        The macro is a no-op on MSVC, which has no equivalent warning.          */
    JUCE_BEGIN_IGNORE_WARNINGS_GCC_LIKE ("-Wfloat-equal")
    bool isExactlyZero (float value) noexcept { return value == 0.0f; }
    JUCE_END_IGNORE_WARNINGS_GCC_LIKE

    /** RMS of a sine at `frequency` after passing through `dsp`, discarding the
        first half of the buffer so the filter's start-up transient does not
        contaminate the measurement. */
    float measureRms (CanaryDsp& dsp, float frequency, int numSamples)
    {
        dsp.reset();

        const auto increment = 2.0 * juce::MathConstants<double>::pi
                               * (double) frequency / testSampleRate;

        double sumOfSquares = 0.0;
        const int firstMeasuredSample = numSamples / 2;

        for (int i = 0; i < numSamples; ++i)
        {
            const auto input  = (float) std::sin (increment * (double) i);
            const auto output = dsp.processSample (0, input);

            if (i >= firstMeasuredSample)
                sumOfSquares += (double) output * (double) output;
        }

        const auto measuredCount = numSamples - firstMeasuredSample;
        return (float) std::sqrt (sumOfSquares / (double) measuredCount);
    }
}

#define CANARY_CHECK(expr, description) \
    reportCheck ((expr), #expr, (description), __FILE__, __LINE__)

int main()
{
    // AudioProcessorValueTreeState attaches listeners, so the message manager
    // has to exist even in a console process.
    juce::ScopedJuceInitialiser_GUI juceInitialiser;

    std::printf ("Canary test suite\n");

    // -----------------------------------------------------------------------
    std::printf ("\nDSP: gain stage\n");
    {
        CanaryDsp dsp;
        dsp.prepare (testSampleRate);
        dsp.setCutoffHz (20000.0f);
        dsp.setGain (0.0f);

        bool allSilent = true;

        for (int i = 0; i < 512; ++i)
            if (! isExactlyZero (dsp.processSample (0, 1.0f)))
                allSilent = false;

        CANARY_CHECK (allSilent,
                      "gain of 0 produces exactly silence, even with a non-zero input");
    }

    // -----------------------------------------------------------------------
    std::printf ("\nDSP: pass-through\n");
    {
        CanaryDsp dsp;
        dsp.prepare (testSampleRate);
        dsp.setCutoffHz (20000.0f);   // far above the band of interest
        dsp.setGain (1.0f);

        float output = 0.0f;

        // A one-pole low-pass settles on a DC input; 4096 samples is far more
        // than enough at this cutoff.
        for (int i = 0; i < 4096; ++i)
            output = dsp.processSample (0, 1.0f);

        CANARY_CHECK (std::abs (output - 1.0f) < 1.0e-4f,
                      "unity gain with a wide-open filter passes DC through unchanged");
    }

    // -----------------------------------------------------------------------
    std::printf ("\nDSP: low-pass response\n");
    {
        CanaryDsp dsp;
        dsp.prepare (testSampleRate);
        dsp.setGain (1.0f);
        dsp.setCutoffHz (1000.0f);

        const auto lowRms  = measureRms (dsp, 200.0f,   8192);
        const auto highRms = measureRms (dsp, 12000.0f, 8192);

        std::printf ("         200 Hz RMS = %.6f, 12 kHz RMS = %.6f\n",
                     (double) lowRms, (double) highRms);

        CANARY_CHECK (highRms < lowRms * 0.5f,
                      "a 1 kHz low-pass attenuates 12 kHz far more than 200 Hz");
        CANARY_CHECK (lowRms > 0.5f,
                      "a 1 kHz low-pass leaves 200 Hz largely intact");
    }

    // -----------------------------------------------------------------------
    std::printf ("\nDSP: state handling\n");
    {
        CanaryDsp dsp;
        dsp.prepare (testSampleRate);
        dsp.setGain (1.0f);
        dsp.setCutoffHz (500.0f);

        for (int i = 0; i < 1024; ++i)
            dsp.processSample (0, 1.0f);   // charge the filter

        dsp.reset();

        CANARY_CHECK (isExactlyZero (dsp.processSample (0, 0.0f)),
                      "reset() clears filter state, so silence in gives silence out");
    }

    // -----------------------------------------------------------------------
    std::printf ("\nDSP: channel independence\n");
    {
        CanaryDsp dsp;
        dsp.prepare (testSampleRate);
        dsp.setGain (1.0f);
        dsp.setCutoffHz (500.0f);

        for (int i = 0; i < 1024; ++i)
            dsp.processSample (0, 1.0f);   // charge channel 0 only

        CANARY_CHECK (isExactlyZero (dsp.processSample (1, 0.0f)),
                      "channel 1 is unaffected by 1024 samples pushed through channel 0");

        // Out-of-range channel indices are clamped rather than read out of bounds.
        const auto clamped = dsp.processSample (99, 0.0f);
        CANARY_CHECK (std::isfinite (clamped),
                      "an out-of-range channel index is clamped, not read out of bounds");
    }

    // -----------------------------------------------------------------------
    std::printf ("\nProcessor: identity and parameters\n");
    {
        CanaryAudioProcessor processor;

        CANARY_CHECK (processor.getName() == juce::String ("Canary"),
                      "the processor reports its name as Canary");

        auto& state = processor.getValueTreeState();

        CANARY_CHECK (state.getParameter (CanaryAudioProcessor::gainParamId)   != nullptr,
                      "the gain parameter is registered");
        CANARY_CHECK (state.getParameter (CanaryAudioProcessor::cutoffParamId) != nullptr,
                      "the cutoff parameter is registered");
        CANARY_CHECK (! processor.acceptsMidi() && ! processor.producesMidi(),
                      "the plugin is an audio effect, not a MIDI device");
    }

    // -----------------------------------------------------------------------
    std::printf ("\nProcessor: state round-trip\n");
    {
        CanaryAudioProcessor processor;
        auto& state = processor.getValueTreeState();

        if (auto* gain = state.getParameter (CanaryAudioProcessor::gainParamId))
            gain->setValueNotifyingHost (0.25f);

        juce::MemoryBlock saved;
        processor.getStateInformation (saved);

        CANARY_CHECK (saved.getSize() > 0,
                      "getStateInformation produces a non-empty block");

        if (auto* gain = state.getParameter (CanaryAudioProcessor::gainParamId))
            gain->setValueNotifyingHost (0.9f);

        processor.setStateInformation (saved.getData(), (int) saved.getSize());

        const auto restored = state.getParameter (CanaryAudioProcessor::gainParamId)->getValue();

        std::printf ("         restored normalised gain = %.6f\n", (double) restored);

        CANARY_CHECK (std::abs (restored - 0.25f) < 1.0e-3f,
                      "a saved state restores the gain parameter it was saved with");
    }

    // -----------------------------------------------------------------------
    std::printf ("\nProcessor: bus layouts\n");
    {
        CanaryAudioProcessor processor;

        juce::AudioProcessor::BusesLayout stereo;
        stereo.inputBuses .add (juce::AudioChannelSet::stereo());
        stereo.outputBuses.add (juce::AudioChannelSet::stereo());

        juce::AudioProcessor::BusesLayout mismatched;
        mismatched.inputBuses .add (juce::AudioChannelSet::mono());
        mismatched.outputBuses.add (juce::AudioChannelSet::stereo());

        CANARY_CHECK (processor.isBusesLayoutSupported (stereo),
                      "stereo in / stereo out is accepted");
        CANARY_CHECK (! processor.isBusesLayoutSupported (mismatched),
                      "mono in / stereo out is rejected: an effect must not change channel count");
    }

    // -----------------------------------------------------------------------
    std::printf ("\nProcessor: processBlock\n");
    {
        CanaryAudioProcessor processor;
        processor.prepareToPlay (testSampleRate, 512);

        juce::AudioBuffer<float> buffer (2, 512);

        for (int ch = 0; ch < buffer.getNumChannels(); ++ch)
            for (int i = 0; i < buffer.getNumSamples(); ++i)
                buffer.setSample (ch, i, 1.0f);

        juce::MidiBuffer midi;
        processor.processBlock (buffer, midi);

        bool everySampleFinite = true;

        for (int ch = 0; ch < buffer.getNumChannels(); ++ch)
            for (int i = 0; i < buffer.getNumSamples(); ++i)
                if (! std::isfinite (buffer.getSample (ch, i)))
                    everySampleFinite = false;

        CANARY_CHECK (everySampleFinite,
                      "processBlock produces only finite samples");
        CANARY_CHECK (buffer.getMagnitude (0, buffer.getNumSamples()) > 0.0f,
                      "processBlock produces a non-silent result for a non-silent input");

        processor.releaseResources();
    }

    // -----------------------------------------------------------------------
    std::printf ("\n%d checks run, %d failed\n", checksRun, checksFailed);

    if (checksFailed > 0)
    {
        std::printf ("CANARY TESTS FAILED\n");
        return 1;
    }

    std::printf ("CANARY TESTS PASSED\n");
    return 0;
}
