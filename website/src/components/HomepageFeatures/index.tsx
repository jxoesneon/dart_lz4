import type {ReactNode} from 'react';
import clsx from 'clsx';
import Heading from '@theme/Heading';
import styles from './styles.module.css';

type FeatureItem = {
  title: string;
  description: ReactNode;
};

const FeatureList: FeatureItem[] = [
  {
    title: 'Guarded Wildcopy',
    description: (
      <>
        Optimized 8-byte chunk copying with a fast 32-bit fallback for Web environments. 
        Enjoy native-like decompression speeds without sacrificing bounds safety or Web compatibility.
      </>
    ),
  },
  {
    title: 'Polymorphic Engine',
    description: (
      <>
        Zero-allocation architecture designed to squeeze maximum performance out of the Dart VM (JIT/AOT). 
        Extremely low garbage collection pressure for high-throughput streaming.
      </>
    ),
  },
  {
    title: 'Reference Standard',
    description: (
      <>
        100% compliant with the official LZ4 block and frame specifications, including LZ4HC, 
        skippable frames, legacy formats, and dictionary compression.
      </>
    ),
  },
];

function Feature({title, description}: FeatureItem) {
  return (
    <div className={clsx('col col--4')}>
      <div className="text--center padding-horiz--md" style={{ marginTop: '2rem', marginBottom: '2rem' }}>
        <Heading as="h3">{title}</Heading>
        <p>{description}</p>
      </div>
    </div>
  );
}

export default function HomepageFeatures(): ReactNode {
  return (
    <section className={styles.features}>
      <div className="container">
        <div className="row">
          {FeatureList.map((props, idx) => (
            <Feature key={idx} {...props} />
          ))}
        </div>
      </div>
    </section>
  );
}
