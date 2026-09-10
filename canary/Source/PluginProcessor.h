#pragma once

#include <juce_audio_processors/juce_audio_processors.h>
#include <juce_audio_basics/juce_audio_basics.h>

#include <array>
#include <cmath>

/**
    The canary's entire DSP: a one-pole low-pass followed by a gain stage.

    It is deliberately tiny and deliberately deterministic. The point of the
    canary is not to sound good, it is to be a *real* plugin whose behaviour can
    be asserted exactly, so that "the pipeline works" means something stronger
    than "the compiler produced a file".

    Kept as a plain class with no JUCE dependency of its own so the tests can
    exercise the same code the plugin ships, without instantiating a host.
*/
class CanaryDsp
{
public:
    static constexpr int maxChannels = 2;

    void prepare (double newSampleRate)
    {
        sampleRate = newSampleRate > 0.0 ? newSampleRate : 44100.0;
        updateCoefficient();
        reset();
    }

    void reset() noexcept
    {
        state.fill (0.0f);
    }

    void setGain (float newGain) noexcept
    {
        gain = juce::jlimit (0.0f, 4.0f, newGain);
    }

    void setCutoffHz (float newCutoffHz) noexcept
    {
        cutoffHz = juce::jlimit (10.0f, 20000.0f, newCutoffHz);
        updateCoefficient();
    }

    float getGain()     const noexcept { return gain; }
    float getCutoffHz() const noexcept { return cutoffHz; }

    /** One-pole low-pass, then gain. Channel index is clamped, never trusted. */
    float processSample (int channel, float input) noexcept
    {
        const auto ch = juce::jlimit (0, maxChannels - 1, channel);
        const auto filtered = state[(size_t) ch] + coefficient * (input - state[(size_t) ch]);
        state[(size_t) ch] = filtered;
        return filtered * gain;
    }

private:
    void updateCoefficient() noexcept
    {
        // Standard one-pole coefficient. At a cutoff far above Nyquist this
        // approaches 1.0, i.e. the filter becomes a pass-through, which is
        // exactly what the "unity gain passes signal" test relies on.
        const auto twoPiFcOverFs = 2.0 * juce::MathConstants<double>::pi * (double) cutoffHz / sampleRate;
        coefficient = (float) juce::jlimit (0.0, 1.0, 1.0 - std::exp (-twoPiFcOverFs));
    }

    double sampleRate  = 44100.0;
    float  cutoffHz    = 8000.0f;
    float  gain        = 0.8f;
    float  coefficient = 0.5f;
    std::array<float, (size_t) maxChannels> state { { 0.0f, 0.0f } };
};

/** The plugin itself. Stereo in, stereo out, two parameters, no surprises. */
class CanaryAudioProcessor final : public juce::AudioProcessor
{
public:
    CanaryAudioProcessor();
    ~CanaryAudioProcessor() override = default;

    void prepareToPlay (double sampleRate, int maximumExpectedSamplesPerBlock) override;
    void releaseResources() override;
    bool isBusesLayoutSupported (const BusesLayout& layouts) const override;
    void processBlock (juce::AudioBuffer<float>&, juce::MidiBuffer&) override;

    // AudioProcessor declares both a float and a double processBlock. Overriding
    // only the float one hides the double one (-Woverloaded-virtual); this brings
    // the base-class overload back into scope so hosts that ask for double
    // precision get JUCE's default conversion rather than a link-time surprise.
    using juce::AudioProcessor::processBlock;

    juce::AudioProcessorEditor* createEditor() override;
    bool hasEditor() const override                          { return true; }

    const juce::String getName() const override              { return "Canary"; }
    bool acceptsMidi() const override                        { return false; }
    bool producesMidi() const override                       { return false; }
    bool isMidiEffect() const override                       { return false; }
    double getTailLengthSeconds() const override             { return 0.0; }

    int getNumPrograms() override                            { return 1; }
    int getCurrentProgram() override                         { return 0; }
    void setCurrentProgram (int) override                    {}
    const juce::String getProgramName (int) override         { return "Default"; }
    void changeProgramName (int, const juce::String&) override {}

    void getStateInformation (juce::MemoryBlock& destData) override;
    void setStateInformation (const void* data, int sizeInBytes) override;

    juce::AudioProcessorValueTreeState& getValueTreeState() noexcept { return parameters; }

    /** Exposed so the tests can drive the real DSP instance. */
    CanaryDsp& getDsp() noexcept { return dsp; }

    static juce::AudioProcessorValueTreeState::ParameterLayout createParameterLayout();

    static constexpr const char* gainParamId   = "gain";
    static constexpr const char* cutoffParamId = "cutoff";

private:
    juce::AudioProcessorValueTreeState parameters;
    std::atomic<float>* gainParam   = nullptr;
    std::atomic<float>* cutoffParam = nullptr;
    CanaryDsp dsp;

    JUCE_DECLARE_NON_COPYABLE_WITH_LEAK_DETECTOR (CanaryAudioProcessor)
};
