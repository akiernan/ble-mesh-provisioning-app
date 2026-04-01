import { useState, useEffect } from 'react';
import { Key, CheckCircle2, Loader2, Lock } from 'lucide-react';
import type { BLEDevice } from '../types';

interface KeyBindingProps {
  devices: BLEDevice[];
  onComplete: () => void;
}

export function KeyBinding({ devices, onComplete }: KeyBindingProps) {
  const [currentStep, setCurrentStep] = useState(0);
  const [isBinding, setIsBinding] = useState(false);
  const [completedSteps, setCompletedSteps] = useState<Set<number>>(new Set());

  const steps = [
    {
      name: 'Generate Application Key',
      description: 'Creating secure 128-bit AES encryption keys',
      icon: Key
    },
    {
      name: 'Distribute Keys',
      description: `Binding keys to ${devices.length} device${devices.length !== 1 ? 's' : ''}`,
      icon: Lock
    },
    {
      name: 'Configure Models',
      description: 'Setting up Generic OnOff and Lighting models',
      icon: CheckCircle2
    },
  ];

  useEffect(() => {
    if (currentStep >= steps.length) {
      setTimeout(() => onComplete(), 1200);
      return;
    }

    let cancelled = false;

    const processStep = async () => {
      if (cancelled) return;

      setIsBinding(true);
      await new Promise(resolve => setTimeout(resolve, 2000));

      if (cancelled) return;

      setCompletedSteps(prev => new Set([...prev, currentStep]));
      setIsBinding(false);

      await new Promise(resolve => setTimeout(resolve, 500));
      if (!cancelled) {
        setCurrentStep(prev => prev + 1);
      }
    };

    processStep();

    return () => {
      cancelled = true;
    };
  }, [currentStep, onComplete]);

  const progress = ((completedSteps.size + (isBinding ? 0.5 : 0)) / steps.length) * 100;

  return (
    <div className="bg-white rounded-2xl shadow-lg overflow-hidden min-h-[600px] flex flex-col">
      <div className="flex-1 p-8">
        <div className="max-w-lg mx-auto space-y-8">
          <div className="text-center space-y-3">
            <div className="inline-flex items-center justify-center w-20 h-20 rounded-full bg-gradient-to-br from-amber-500 to-orange-500 mb-2">
              <Key className="w-10 h-10 text-white" />
            </div>
            <h1 className="text-4xl font-bold text-slate-900">Key Binding</h1>
            <p className="text-lg text-slate-600">
              Configuring secure communication
            </p>
          </div>

          <div className="space-y-6">
            <div className="space-y-3">
              <div className="flex justify-between text-sm font-medium text-slate-600">
                <span>Configuration Progress</span>
                <span>{completedSteps.size} of {steps.length} steps</span>
              </div>
              <div className="w-full h-3 bg-slate-200 rounded-full overflow-hidden">
                <div
                  className="h-full bg-gradient-to-r from-amber-600 to-orange-600 transition-all duration-300 ease-out"
                  style={{ width: `${progress}%` }}
                />
              </div>
            </div>

            <div className="space-y-3">
              {steps.map((step, index) => {
                const isCompleted = completedSteps.has(index);
                const isCurrent = index === currentStep;
                const isPending = index > currentStep;
                const Icon = step.icon;

                return (
                  <div
                    key={index}
                    className={`p-5 rounded-xl border-2 transition-all ${
                      isCompleted
                        ? 'border-green-200 bg-green-50'
                        : isCurrent
                        ? 'border-amber-500 bg-amber-50 shadow-md'
                        : 'border-slate-200 bg-slate-50'
                    }`}
                  >
                    <div className="flex items-start space-x-4">
                      <div className="flex-shrink-0 pt-1">
                        {isCompleted && (
                          <div className="w-10 h-10 rounded-full bg-green-500 flex items-center justify-center">
                            <CheckCircle2 className="w-6 h-6 text-white" />
                          </div>
                        )}
                        {isCurrent && (
                          <div className="w-10 h-10 rounded-full bg-amber-500 flex items-center justify-center">
                            <Loader2 className="w-6 h-6 text-white animate-spin" />
                          </div>
                        )}
                        {isPending && (
                          <div className="w-10 h-10 rounded-full border-2 border-slate-300 bg-white flex items-center justify-center">
                            <Icon className="w-5 h-5 text-slate-400" />
                          </div>
                        )}
                      </div>
                      <div className="flex-1">
                        <div className="font-semibold text-slate-900">{step.name}</div>
                        <div className={`text-sm mt-1 ${
                          isCompleted ? 'text-green-600' :
                          isCurrent ? 'text-amber-600' :
                          'text-slate-500'
                        }`}>
                          {step.description}
                        </div>
                      </div>
                    </div>
                  </div>
                );
              })}
            </div>

            <div className="bg-blue-50 border-2 border-blue-200 rounded-xl p-5">
              <div className="flex items-start space-x-3">
                <div className="w-6 h-6 rounded-full bg-blue-600 flex items-center justify-center flex-shrink-0 mt-0.5">
                  <Lock className="w-3.5 h-3.5 text-white" />
                </div>
                <div className="text-sm">
                  <div className="font-semibold text-blue-900 mb-1">Security Information</div>
                  <div className="text-blue-700 leading-relaxed">
                    All mesh communication uses AES-CCM encryption with unique application keys.
                    Your devices are secured with industry-standard cryptography.
                  </div>
                </div>
              </div>
            </div>
          </div>

          {completedSteps.size === steps.length && (
            <div className="text-center space-y-4 pt-4">
              <div className="inline-flex items-center justify-center w-16 h-16 rounded-full bg-green-100">
                <CheckCircle2 className="w-8 h-8 text-green-600" />
              </div>
              <p className="text-green-600 font-semibold text-lg">
                Key binding completed!
              </p>
            </div>
          )}
        </div>
      </div>
    </div>
  );
}
