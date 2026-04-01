import { createBrowserRouter } from 'react-router';
import { DeviceDiscoveryPage } from './pages/DeviceDiscoveryPage';
import { ProvisioningPage } from './pages/ProvisioningPage';
import { KeyBindingPage } from './pages/KeyBindingPage';
import { GroupConfigPage } from './pages/GroupConfigPage';
import { DeviceControlPage } from './pages/DeviceControlPage';

export const router = createBrowserRouter([
  {
    path: '/',
    Component: DeviceDiscoveryPage,
  },
  {
    path: '/provisioning',
    Component: ProvisioningPage,
  },
  {
    path: '/key-binding',
    Component: KeyBindingPage,
  },
  {
    path: '/group-config',
    Component: GroupConfigPage,
  },
  {
    path: '/control',
    Component: DeviceControlPage,
  },
]);
