import { Container, getContainer } from '@cloudflare/containers';

export class SocialSaveContainer extends Container {
  defaultPort = 8000;
  sleepAfter = '30m';
  envVars = {
    ENVIRONMENT: 'production',
    REQUIRE_API_KEY: 'false',
    SECRET_KEY: 'socialsave-cloudflare-hmac-change-me',
  };
}

export default {
  async fetch(
    request: Request,
    env: { SOCIALSAVE: DurableObjectNamespace<SocialSaveContainer> },
  ): Promise<Response> {
    const container = getContainer(env.SOCIALSAVE, 'api');
    return container.fetch(request);
  },
};
