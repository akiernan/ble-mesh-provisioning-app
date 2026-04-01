import { useState, useEffect } from 'react';
import { Shield, CheckCircle2, Loader2, Network } from 'lucide-react';
import type { BLEDevice } from '../types';

interface ProvisioningProps {
  devices: BLEDevice[];
  onComplete: () => void;
}

export function Provisioning({ devices, onComplete }: ProvisioningProps) {
  const [currentIndex, setCurrentIndex] = useState(0);
  const [provisionedIds, setProvisionedIds] = useState<Set<string>>(new Set());
  const [isProvisioning, setIsProvisioning] = useState(false);
  const [progress, setProgress] = useState(0);

  useEffect(() => {
    if (currentIndex >= devices.length) {
      // All devices provisioned
      setTimeout(() => onComplete(), 1200);
      return;
    }

    let cancelled = false;

    const provisionDevice = async () => {
      if (cancelled) return;

      setIsProvisioning(true);
      const device = devices[currentIndex];

      const steps = 5;
      for (let i = 0; i <= steps; i++) {
        if (cancelled) return;
        setProgress((i / steps) * 100);
        await new Promise(resolve => setTimeout(resolve, 500));
      }

      if (cancelled) return;
      await new Promise(resolve => setTimeout(resolve, 300));

      setProvisionedIds(prev => new Set([...prev, device.id]));
      setIsProvisioning(false);
      setProgress(0);

      await new Promise(resolve => setTimeout(resolve, 400));
      if (!cancelled) {
        setCurrentIndex(prev => prev + 1);
      }
    };

    provisionDevice();

    return () => {
      cancelled = true;
    };
  }, [currentIndex, devices, onComplete]);

  const totalProgress = ((provisionedIds.size + (isProvisioning ? progress / 100 : 0)) / devices.length) * 100;

  return (
    <div className="bg-white rounded-2xl shadow-lg overflow-hidden min-h-[600px] flex flex-col">
      <div className="flex-1 p-8">
        <div className="max-w-lg mx-auto space-y-8">
          <div className="text-center space-y-3">
            <div className="inline-flex items-center justify-center w-20 h-20 rounded-full bg-gradient-to-br from-purple-500 to-pink-500 mb-2">
              <Shield className="w-10 h-10 text-white" />
            </div>
            <h1 className="text-4xl font-bold text-slate-900">Provisioning</h1>
            <p className="text-lg text-slate-600">
              Adding devices to the mesh network securely
            </p>
          </div>

          <div className="space-y-6">
            <div className="space-y-3">
              <div className="flex justify-between text-sm font-medium text-slate-600">
                <span>Overall Progress</span>
                <span>{provisionedIds.size} of {devices.length} complete</span>
              </div>
              <div className="w-full h-3 bg-slate-200 rounded-full overflow-hidden">
                <div
                  className="h-full bg-gradient-to-r from-purple-600 to-pink-600 transition-all duration-300 ease-out"
                  style={{ width: `${totalProgress}%` }}
                />
              </div>
            </div>

            <div className="space-y-3">
              {devices.map((device, index) => {
                const isProvisioned = provisionedIds.has(device.id);
                const isCurrent = index === currentIndex;
                const isPending = index > currentIndex;

                return (
                  <div
                    key={device.id}
                    className={`p-5 rounded-xl border-2 transition-all ${
                      isProvisioned
                        ? 'border-green-200 bg-green-50'
                        : isCurrent
                        ? 'border-purple-500 bg-purple-50 shadow-md'
                        : 'border-slate-200 bg-slate-50'
                    }`}
                  >
                    <div className="flex items-center justify-between">
                      <div className="flex items-center space-x-4">
                        <div className="flex-shrink-0">
                          {isProvisioned && (
                            <div className="w-10 h-10 rounded-full bg-green-500 flex items-center justify-center">
                              <CheckCircle2 className="w-6 h-6 text-white" />
                            </div>
                          )}
                          {isCurrent && (
                            <div className="w-10 h-10 rounded-full bg-purple-500 flex items-center justify-center">
                              <Loader2 className="w-6 h-6 text-white animate-spin" />
                            </div>
                          )}
                          {isPending && (
                            <div className="w-10 h-10 rounded-full border-2 border-slate-300 bg-white flex items-center justify-center">
                              <Network className="w-5 h-5 text-slate-400" />
                            </div>
                          )}
                        </div>
                        <div>
                          <div className="font-semibold text-slate-900">{device.name}</div>
                          <div className="text-sm">
                            {isProvisioned && <span className="text-green-600 font-medium">Provisioned</span>}
                            {isCurrent && <span className="text-purple-600 font-medium">Provisioning...</span>}
                            {isPending && <span className="text-slate-500">Waiting</span>}
                          </div>
                        </div>
                      </div>
                      {isCurrent && isProvisioning && (
                        <div className="text-lg font-bold text-purple-600">
                          {progress.toFixed(0)}%
                        </div>
                      )}
                    </div>
                    {isCurrent && isProvisioning && (
                      <div className="mt-3 w-full h-2 bg-purple-200 rounded-full overflow-hidden">
                        <div
                          className="h-full bg-purple-600 transition-all duration-300"
                          style={{ width: `${progress}%` }}
                        />
                      </div>
                    )}
                  </div>
                );
              })}
            </div>
          </div>

          {provisionedIds.size === devices.length && (
            <div className="text-center space-y-4 pt-4">
              <div className="inline-flex items-center justify-center w-16 h-16 rounded-full bg-green-100">
                <CheckCircle2 className="w-8 h-8 text-green-600" />
              </div>
              <p className="text-green-600 font-semibold text-lg">
                All devices provisioned successfully!
              </p>
            </div>
          )}
        </div>
      </div>
    </div>
  );
}
